-- | In-process pub/sub broker for the live transcript streaming feature.
--
-- The broker fans out 'BrokerEvent's to a bounded set of subscribers via
-- per-subscriber 'TBQueue's. Publish is non-blocking and STM-atomic: under
-- contention a full subscriber queue has its oldest entry dropped, its
-- overflow flag set, and the new entry written — all in a single
-- transaction.
--
-- The broker is origin-agnostic; per-origin caps are enforced at the WS
-- handler layer (WU3) by a separate 'StreamGuard'. The broker only enforces
-- the global subscriber cap configured by '_bc_maxSubscribers'.
--
-- See "docs/transcript-streaming.md" §Broker for the full design.
module PureClaw.Frontend.StreamBroker
  ( -- * Broker handle
    StreamBroker (..)
    -- * Events
  , BrokerEvent (..)
  , SessionActivity (..)
    -- * Subscription
  , Subscription (..)
  , SubscriberId (..)
    -- * Errors
  , BrokerError (..)
    -- * Introspection
  , BrokerStats (..)
    -- * Configuration
  , BrokerConfig (..)
  , defaultBrokerConfig
    -- * Constructor
  , mkInProcessBroker
  ) where

import Data.Aeson (Value)
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TVar
  , atomically
  , isFullTBQueue
  , lengthTBQueue
  , modifyTVar'
  , newTBQueue
  , newTVar
  , newTVarIO
  , readTBQueue
  , readTVar
  , readTVarIO
  , writeTBQueue
  , writeTVar
  )
import Control.Monad (forM, forM_, when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)

import PureClaw.Core.Types (SessionId)
import PureClaw.Frontend.Activity.Types (HarnessActivity (..))
import PureClaw.Session.Types (SessionMeta)
import PureClaw.Transcript.Types (TranscriptEntry)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- | Tagged event published by writers and consumed by subscribers (WS
-- handlers). 'EntryRecorded' carries the full transcript entry; subscribers
-- filter by 'SessionId' when delivering to their peer. 'ActivityChanged'
-- carries lightweight per-session signals that the frontend uses for the
-- sidebar.
data BrokerEvent
  = EntryRecorded   !SessionId !TranscriptEntry
    -- | An in-progress (ephemeral) harness message was updated in-place.
    -- Subscribers that are currently replaying this session drop the event
    -- (it will be re-sent on the next tick); all other focused subscribers
    -- forward it immediately as a 'SeEntryUpdate' wire event.
  | EntryUpdated    !SessionId !TranscriptEntry
  | ActivityChanged !SessionId !SessionActivity
    -- | Full sidebar list snapshot (tabs + recent + archived) pushed on
    -- every mutation and once on WS connect. Carries pre-serialized JSON
    -- so the WS handler can send it without knowing the domain types.
  | ListsSnapshot   !Value
  deriving stock (Show, Eq)

-- | Per-session live signals for sidebar/tab indicators.
data SessionActivity
  = -- | A new entry was recorded at this timestamp; carries no payload (the
    -- entry itself rides on the companion 'EntryRecorded' publish).
    SaEntryAt !UTCTime
    -- | The session's harness transitioned to a new activity state.
  | SaHarnessStatus !HarnessActivity
    -- | A new session appeared (carries its meta so the sidebar can render
    -- it immediately).
  | SaSessionCreated !SessionMeta
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Subscription
-- ---------------------------------------------------------------------------

-- | Opaque identifier for a subscriber, allocated by the broker via a
-- monotonically increasing STM counter.
newtype SubscriberId = SubscriberId { unSubscriberId :: Int }
  deriving stock (Show, Eq, Ord)

-- | Subscription handle returned by '_streamBroker_subscribe'. The WS
-- handler reads from '_sub_queue' for events and from '_sub_overflow' for
-- the overflow signal (via STM @orElse@). On disconnect the handler must
-- invoke '_sub_cancel' to atomically remove the subscriber from the broker.
data Subscription = Subscription
  { _sub_queue    :: !(TBQueue BrokerEvent)
  , _sub_overflow :: !(TVar Bool)
  , _sub_cancel   :: !(IO ())
  }

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Broker-level subscribe failures. The WS handler maps
-- 'SubscriberCapReached' to a 503 on the upgrade.
data BrokerError
  = SubscriberCapReached
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Introspection
-- ---------------------------------------------------------------------------

-- | Snapshot of broker state used by tests and operators. Cheap to compute
-- (one STM transaction).
data BrokerStats = BrokerStats
  { _bs_subscriberCount :: !Int
  , _bs_queueDepths     :: ![Int]
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | Static configuration for an in-process broker. All caps are enforced at
-- broker boundaries; per-origin enforcement is the WS handler's
-- responsibility ('_bc_maxSubsPerOrigin' is provided here so that handler
-- code can read a single source of truth via '_streamBroker_config').
data BrokerConfig = BrokerConfig
  { -- | Per-subscriber 'TBQueue' depth.
    _bc_queueDepth       :: !Int
    -- | Per-process subscriber cap.
  , _bc_maxSubscribers   :: !Int
    -- | Per-origin subscriber cap (enforced by the WS handler's
    -- 'StreamGuard', not by the broker itself).
  , _bc_maxSubsPerOrigin :: !Int
    -- | Per-event payload byte cap. Larger entries are truncated upstream
    -- by 'BroadcastingTranscriptHandle' (WU2) before publish.
  , _bc_maxEventBytes    :: !Int
  }
  deriving stock (Show, Eq)

-- | Default config: queue depth 256, 32 subscribers, 8 per origin, 256 KB
-- per event.
defaultBrokerConfig :: BrokerConfig
defaultBrokerConfig =
  BrokerConfig
    { _bc_queueDepth       = 256
    , _bc_maxSubscribers   = 32
    , _bc_maxSubsPerOrigin = 8
    , _bc_maxEventBytes    = 256 * 1024
    }

-- ---------------------------------------------------------------------------
-- Broker handle
-- ---------------------------------------------------------------------------

-- | Pub/sub broker capability. All operations are 'IO' so the broker can
-- be passed across thread boundaries (it lives at the lifetime of the
-- process).
data StreamBroker = StreamBroker
  { -- | Non-blocking publish to all current subscribers. STM-atomic:
    -- enqueue or (on full queue) pop oldest + enqueue + set overflow flag,
    -- in a single transaction across every subscriber.
    _streamBroker_publish    :: BrokerEvent -> IO ()
    -- | Allocate a new subscription. Returns 'Left' 'SubscriberCapReached'
    -- when the per-process subscriber cap is reached.
  , _streamBroker_subscribe  :: IO (Either BrokerError Subscription)
    -- | Snapshot of broker state (subscriber count + per-subscriber queue
    -- depths). Cheap; STM-atomic.
  , _streamBroker_introspect :: IO BrokerStats
    -- | Read-only accessor exposing the configuration. WU2's
    -- 'BroadcastingTranscriptHandle' reads '_bc_maxEventBytes' through
    -- this; the WS handler reads '_bc_maxSubsPerOrigin'.
  , _streamBroker_config     :: BrokerConfig
    -- | Most-recent 'HarnessActivity' observed for a session via an
    -- 'ActivityChanged' / 'SaHarnessStatus' publish, or 'Nothing' if no
    -- such event has been seen. The WS handler reads this on a fresh
    -- focus so a client connecting mid-request sees the in-flight
    -- thinking state immediately, rather than waiting for the next
    -- transition.
  , _streamBroker_currentActivity :: SessionId -> IO (Maybe HarnessActivity)
  }

-- ---------------------------------------------------------------------------
-- In-process broker implementation
-- ---------------------------------------------------------------------------

-- | The mutable state of an in-process broker.
data BrokerState = BrokerState
  { _bst_nextId           :: !(TVar Int)
  , _bst_subscribers      :: !(TVar (Map SubscriberId Subscription))
    -- | Latest 'SaHarnessStatus' seen for each session. Updated inside the
    -- same STM transaction as the publish so a focus snapshot taken just
    -- after a publish observes the post-publish state.
  , _bst_currentActivity  :: !(TVar (Map SessionId HarnessActivity))
  }

-- | Construct an in-process broker. The broker exists for the lifetime of
-- the process and is shared across every write site, the activity probe,
-- and every WS connection. There is exactly one broker per binary main
-- process (see the design's lifecycle section).
mkInProcessBroker :: BrokerConfig -> IO StreamBroker
mkInProcessBroker cfg = do
  state <- BrokerState
    <$> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
  pure StreamBroker
    { _streamBroker_publish          = publishEvent state
    , _streamBroker_subscribe        = subscribeNew cfg state
    , _streamBroker_introspect       = introspect state
    , _streamBroker_config           = cfg
    , _streamBroker_currentActivity  = currentActivity state
    }

-- ---------------------------------------------------------------------------
-- Publish
-- ---------------------------------------------------------------------------

-- | Publish to every current subscriber in a single STM transaction.
--
-- For each subscriber, if its queue is full: drop the oldest entry, set its
-- overflow 'TVar', then write the new entry. Otherwise just write the new
-- entry. Performing all subscriber updates inside one 'atomically' block
-- gives the design's linearizability guarantee (D3): any later
-- 'atomically' read from a subscriber observes either the pre- or
-- post-publish state for every subscriber, never a mix.
publishEvent :: BrokerState -> BrokerEvent -> IO ()
publishEvent state ev = atomically $ do
  -- Record the latest harness status for the affected session before fanning
  -- out so a subsequent 'currentActivity' read observes the post-publish
  -- value. Only 'SaHarnessStatus' contributes to the snapshot; entry/created
  -- events carry no persistent state we need to replay on focus.
  case ev of
    ActivityChanged sid (SaHarnessStatus s) ->
      modifyTVar' (_bst_currentActivity state) (Map.insert sid s)
    _ -> pure ()
  subs <- readTVar (_bst_subscribers state)
  forM_ (Map.elems subs) $ \sub -> publishOne sub ev

-- | Read the most recent 'HarnessActivity' the broker has observed for a
-- session. STM-atomic and cheap.
currentActivity :: BrokerState -> SessionId -> IO (Maybe HarnessActivity)
currentActivity state sid =
  Map.lookup sid <$> readTVarIO (_bst_currentActivity state)

-- | Enqueue one event to one subscriber under the overflow protocol.
-- Pure-STM so multiple invocations compose inside the publish transaction.
publishOne :: Subscription -> BrokerEvent -> STM ()
publishOne sub ev = do
  full <- isFullTBQueue (_sub_queue sub)
  when full $ do
    _ <- readTBQueue (_sub_queue sub)
    writeTVar (_sub_overflow sub) True
  writeTBQueue (_sub_queue sub) ev

-- ---------------------------------------------------------------------------
-- Subscribe
-- ---------------------------------------------------------------------------

-- | Allocate a new subscriber slot. Enforces the per-process subscriber cap
-- ('_bc_maxSubscribers'). Returns 'Left' 'SubscriberCapReached' when the
-- cap is reached; the WS handler maps this to a 503.
subscribeNew
  :: BrokerConfig
  -> BrokerState
  -> IO (Either BrokerError Subscription)
subscribeNew cfg state = atomically $ do
  subs <- readTVar (_bst_subscribers state)
  if Map.size subs >= _bc_maxSubscribers cfg
    then pure (Left SubscriberCapReached)
    else do
      nextId <- readTVar (_bst_nextId state)
      writeTVar (_bst_nextId state) (nextId + 1)
      let sid = SubscriberId nextId
      queue    <- newTBQueue (fromIntegral (_bc_queueDepth cfg))
      overflow <- newTVar False
      let sub = Subscription
            { _sub_queue    = queue
            , _sub_overflow = overflow
            , _sub_cancel   = cancelSubscriber state sid
            }
      modifyTVar' (_bst_subscribers state) (Map.insert sid sub)
      pure (Right sub)

-- | Remove a subscriber from the broker map atomically. Idempotent — a
-- second call is a no-op (the WS handler may invoke this from both the
-- bracket cleanup and an error path; the no-op is intentional).
cancelSubscriber :: BrokerState -> SubscriberId -> IO ()
cancelSubscriber state sid =
  atomically $ modifyTVar' (_bst_subscribers state) (Map.delete sid)

-- ---------------------------------------------------------------------------
-- Introspect
-- ---------------------------------------------------------------------------

-- | Snapshot the broker's state. The per-subscriber queue depths are read
-- atomically alongside the subscriber count so the resulting 'BrokerStats'
-- reflects a single point in time.
introspect :: BrokerState -> IO BrokerStats
introspect state = do
  subs <- readTVarIO (_bst_subscribers state)
  let elems = Map.elems subs
  depths <- atomically $ forM elems $ \sub ->
    fromIntegral <$> lengthTBQueue (_sub_queue sub)
  pure BrokerStats
    { _bs_subscriberCount = Map.size subs
    , _bs_queueDepths     = depths
    }
