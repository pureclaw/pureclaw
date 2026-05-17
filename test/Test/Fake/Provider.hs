-- |
-- Module      : Test.Fake.Provider
-- Description : T1 — recording 'Provider' test seam used by tabbed-chat specs.
--
-- A 'Provider' implementation that records every 'CompletionRequest' into a
-- shared 'TVar' and serves canned responses. Includes a 'TMVar'-blocking
-- variant for concurrency tests (C1, C6, D-series).
--
-- This seam exists so the LLM-free invariant (P18) can be asserted by
-- inspecting the recorded request list — any input that takes the
-- @Switch | Inject | SlashCmd@ path must NOT cause a recorded request.
--
-- See @docs/tabbed-chat.md@ §"Test seams (T-series)" T1.
module Test.Fake.Provider
  ( -- * Recorded provider
    FakeProvider
  , newFakeProvider
  , takeRecorded
  , peekRecorded
    -- * Canned response helpers
  , queueResponse
  , queueResponses
    -- * Blocking variant
  , BlockingProvider
  , newBlockingProvider
  , releaseBlockingResponse
  , takeBlockingRecorded
  ) where

import Control.Concurrent.STM
  ( STM
  , TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTVar
  , readTVarIO
  , takeTMVar
  , writeTVar
  )
import Data.Maybe qualified as Maybe
import Data.Text qualified as T

import PureClaw.Core.Types
import PureClaw.Providers.Class

-- ---------------------------------------------------------------------------
-- Recording provider
-- ---------------------------------------------------------------------------

-- | A 'Provider' that records every invocation into a 'TVar' and serves
-- canned responses from a queue. If the queue is empty when 'complete' is
-- called, a stub response containing the empty text is returned (so tests
-- focused on the recorded-request invariant can ignore response content).
data FakeProvider = FakeProvider
  { _fp_recorded  :: !(TVar [CompletionRequest])
  , _fp_responses :: !(TVar [CompletionResponse])
  }

-- | Create a fresh fake provider with an empty record and no queued
-- responses.
newFakeProvider :: IO FakeProvider
newFakeProvider = FakeProvider <$> newTVarIO [] <*> newTVarIO []

-- | Atomically drain all recorded requests (oldest-first) and clear the log.
takeRecorded :: FakeProvider -> IO [CompletionRequest]
takeRecorded fp = atomically $ do
  rs <- readTVar (_fp_recorded fp)
  writeTVar (_fp_recorded fp) []
  pure (reverse rs)

-- | Peek at recorded requests without clearing.
peekRecorded :: FakeProvider -> IO [CompletionRequest]
peekRecorded fp = reverse <$> readTVarIO (_fp_recorded fp)

-- | Queue one canned response to be returned on the next 'complete' call.
queueResponse :: FakeProvider -> CompletionResponse -> IO ()
queueResponse fp r = atomically (modifyTVar' (_fp_responses fp) (++ [r]))

-- | Queue many canned responses in order.
queueResponses :: FakeProvider -> [CompletionResponse] -> IO ()
queueResponses fp rs = atomically (modifyTVar' (_fp_responses fp) (++ rs))

stubResponse :: ModelId -> CompletionResponse
stubResponse m = CompletionResponse
  { _crsp_content = [TextBlock T.empty]
  , _crsp_model   = m
  , _crsp_usage   = Nothing
  }

instance Provider FakeProvider where
  complete fp req = do
    resp <- atomically $ do
      modifyTVar' (_fp_recorded fp) (req :)
      qs <- readTVar (_fp_responses fp)
      case qs of
        []     -> pure Nothing
        (r:rs) -> writeTVar (_fp_responses fp) rs >> pure (Just r)
    pure (Maybe.fromMaybe (stubResponse (_cr_model req)) resp)

  completeStream fp req cb = do
    resp <- complete fp req
    cb (StreamDone resp)

  listModels _ = pure []

-- ---------------------------------------------------------------------------
-- Blocking provider (TMVar-gated)
-- ---------------------------------------------------------------------------

-- | A 'Provider' whose 'complete' call blocks on a 'TMVar' until the test
-- explicitly releases a response. Used by C1, C6, D-series concurrency tests
-- where the provider must be held mid-call to exercise focus switches and
-- cancellation semantics.
data BlockingProvider = BlockingProvider
  { _bp_recorded :: !(TVar [CompletionRequest])
  , _bp_gate     :: !(TMVar CompletionResponse)
  }

-- | Create a blocking provider with no queued responses; the next
-- 'complete' call will block until 'releaseBlockingResponse' is invoked.
newBlockingProvider :: IO BlockingProvider
newBlockingProvider = BlockingProvider <$> newTVarIO [] <*> newEmptyTMVarIO

-- | Release one canned response into the gate, unblocking exactly one
-- pending or future 'complete' caller.
releaseBlockingResponse :: BlockingProvider -> CompletionResponse -> IO ()
releaseBlockingResponse bp r = atomically (putTMVar (_bp_gate bp) r)

-- | Drain recorded requests from a blocking provider (oldest-first).
takeBlockingRecorded :: BlockingProvider -> IO [CompletionRequest]
takeBlockingRecorded bp = atomically $ do
  rs <- readTVar (_bp_recorded bp)
  writeTVar (_bp_recorded bp) []
  pure (reverse rs)

instance Provider BlockingProvider where
  complete bp req = do
    record bp req
    atomically (takeTMVar (_bp_gate bp))

  completeStream bp req cb = do
    resp <- complete bp req
    cb (StreamDone resp)

  listModels _ = pure []

record :: BlockingProvider -> CompletionRequest -> IO ()
record bp req = atomically (recordSTM bp req)

recordSTM :: BlockingProvider -> CompletionRequest -> STM ()
recordSTM bp req = modifyTVar' (_bp_recorded bp) (req :)
