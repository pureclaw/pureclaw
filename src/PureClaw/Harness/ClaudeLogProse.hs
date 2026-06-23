-- | Pure prose fold over claude-code JSONL session-log lines.
--
-- This module extracts ONLY the assistant @text@ blocks from a claude-code
-- JSONL log, accumulating them turn-by-turn into a sanitized prose string.
-- It is the pure heart of the claude-log content source — no IO, fully
-- unit-testable.
--
-- == Fold rules (prose-only)
--
-- * An @assistant@ event appends its @text@ content blocks (each one
--   sanitized via 'sanitizeHarnessOutput') to the current turn's prose.
--   The @_pt_sourceUuid@ is pinned to the FIRST assistant line's @uuid@
--   and MUST NOT change as later assistant lines arrive (stable derived
--   turn-id).
--
-- * A terminal @stop_reason@ (@end_turn@, @stop_sequence@, @max_tokens@)
--   on an assistant event sets @_pt_finalized = True@.  A @stop_reason@
--   of @tool_use@ does NOT finalize (the turn will continue after the
--   tool call returns).
--
-- * A @user@ event whose @message.content@ is NOT solely @tool_result@
--   blocks ends the current turn (finalizing it if it had prose) and
--   starts a fresh empty turn.
--
-- * A @user@ event whose content IS solely @tool_result@ blocks does NOT
--   end the turn (it is the tool-call return, not a real user message).
--
-- * @thinking@, @tool_use@, and @tool_result@ assistant content blocks
--   are silently ignored.
--
-- * Unknown event types, malformed JSON, and missing\/wrong-typed fields
--   leave the state unchanged and yield 'Nothing'.  Total — never throws.
module PureClaw.Harness.ClaudeLogProse
  ( -- * State
    ProseState
  , emptyProseState
    -- * Per-turn result
  , ProseTurn (..)
    -- * Fold step
  , foldProseLine
    -- * State accessor
  , currentProseTurn
    -- * Stable turn-id derivation
  , deriveTurnId
  ) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as V5
import Data.Vector qualified as V
import Data.Word (Word8)

import PureClaw.Handles.Harness (sanitizeHarnessOutput)
import PureClaw.Harness.ClaudeLogConvert
  ( decodeObject
  , lookupObject
  , lookupText
  )

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | The result of one updated or finalized prose turn.
data ProseTurn = ProseTurn
  { _pt_sourceUuid :: !Text   -- ^ Pinned to the FIRST assistant line's @uuid@.
  , _pt_text       :: !Text   -- ^ Accumulated sanitized assistant prose.
  , _pt_finalized  :: !Bool   -- ^ True iff a terminal @stop_reason@ was seen.
  } deriving stock (Eq, Show)

-- | Opaque accumulator for 'foldProseLine'.  Callers obtain the initial
-- value via 'emptyProseState' and inspect it via 'currentProseTurn' or
-- the 'Maybe ProseTurn' returned by each 'foldProseLine' call.
newtype ProseState = ProseState
  { _ps_turn :: Maybe ActiveTurn
  } deriving stock (Eq, Show)

-- | The in-progress turn being accumulated (internal).
data ActiveTurn = ActiveTurn
  { _at_sourceUuid :: !Text
  , _at_text       :: !Text
  , _at_finalized  :: !Bool
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Smart constructors / accessors
-- ---------------------------------------------------------------------------

-- | The initial prose accumulator: no active turn.
emptyProseState :: ProseState
emptyProseState = ProseState { _ps_turn = Nothing }

-- | Return the current 'ProseTurn' only when it has visible prose or is
-- finalized.  An empty un-finalized turn is invisible.
currentProseTurn :: ProseState -> Maybe ProseTurn
currentProseTurn ps = _ps_turn ps >>= turnIfVisible

-- | Yield the turn only when it has visible prose or is finalized.
turnIfVisible :: ActiveTurn -> Maybe ProseTurn
turnIfVisible at
  | T.null (_at_text at) && not (_at_finalized at) = Nothing
  | otherwise = Just ProseTurn
      { _pt_sourceUuid = _at_sourceUuid at
      , _pt_text       = _at_text at
      , _pt_finalized  = _at_finalized at
      }

-- ---------------------------------------------------------------------------
-- Fold step
-- ---------------------------------------------------------------------------

-- | Fold one complete JSONL 'ByteString' line into 'ProseState'.
--
-- Returns the updated state and, when the turn's visible content changes
-- (prose grew or finalized flag flipped), the current 'ProseTurn'.
-- Total: any malformed\/unknown\/meta line leaves state unchanged and
-- returns 'Nothing'.  Never throws.
foldProseLine :: ByteString -> ProseState -> (ProseState, Maybe ProseTurn)
foldProseLine raw ps =
  case decodeObject raw of
    Nothing  -> noChange ps
    Just obj -> dispatchEvent obj ps

-- | Leave state unchanged.
noChange :: ProseState -> (ProseState, Maybe ProseTurn)
noChange ps = (ps, Nothing)

-- | Route by @type@ field; unknown\/meta types → no change.
dispatchEvent :: KeyMap Value -> ProseState -> (ProseState, Maybe ProseTurn)
dispatchEvent obj ps =
  case lookupText "type" obj of
    Just "assistant" -> handleAssistant obj ps
    Just "user"      -> handleUser obj ps
    _                -> noChange ps

-- ---------------------------------------------------------------------------
-- Assistant event
-- ---------------------------------------------------------------------------

-- | Process an @assistant@ event: append sanitized @text@ blocks, pin uuid
-- to the first line, finalize on a terminal @stop_reason@.
handleAssistant :: KeyMap Value -> ProseState -> (ProseState, Maybe ProseTurn)
handleAssistant obj ps =
  case (lookupText "uuid" obj, lookupObject "message" obj) of
    (Just uuid, Just msg) ->
      let prose     = extractProse msg
          stopR     = lookupText "stop_reason" msg
          finalized = isTerminal stopR
      in  if T.null prose && not finalized
            then noChange ps
            else
              let at' = applyToTurn uuid prose finalized (_ps_turn ps)
                  ps' = ps { _ps_turn = Just at' }
              in  (ps', turnIfVisible at')
    _ -> noChange ps

-- | Incorporate new prose + finalized flag into the current 'ActiveTurn',
-- pinning @uuid@ only on the FIRST assistant line.
applyToTurn :: Text -> Text -> Bool -> Maybe ActiveTurn -> ActiveTurn
applyToTurn uuid prose finalized Nothing =
  ActiveTurn
    { _at_sourceUuid = uuid
    , _at_text       = prose
    , _at_finalized  = finalized
    }
applyToTurn _uuid prose finalized (Just at) =
  at { _at_text     = _at_text at <> prose
     , _at_finalized = _at_finalized at || finalized
     }

-- | True iff the @stop_reason@ is a turn-terminal reason.
-- @tool_use@ is intentionally NOT terminal.
isTerminal :: Maybe Text -> Bool
isTerminal (Just "end_turn")      = True
isTerminal (Just "stop_sequence") = True
isTerminal (Just "max_tokens")    = True
isTerminal _                      = False

-- | Collect all @text@ block values from @message.content@, sanitized via
-- 'sanitizeHarnessOutput'.  Non-text block types are silently skipped.
extractProse :: KeyMap Value -> Text
extractProse msg =
  case KeyMap.lookup (Key.fromText "content") msg of
    Just (Array blocks) -> T.concat (map extractTextBlock (V.toList blocks))
    _                   -> ""

-- | Extract the sanitized text from a single content block.
-- Returns empty text for non-text blocks (@thinking@, @tool_use@, etc.).
extractTextBlock :: Value -> Text
extractTextBlock (Object km) =
  case lookupText "type" km of
    Just "text" -> maybe "" sanitizeHarnessOutput (lookupText "text" km)
    _ -> ""
extractTextBlock _ = ""

-- ---------------------------------------------------------------------------
-- User event
-- ---------------------------------------------------------------------------

-- | Process a @user@ event.
--
-- If the content is NOT solely @tool_result@ blocks, this is a real user
-- message and ends the current turn (resetting to no active turn).
--
-- Backstop finalize: if the active turn has non-empty content and was NOT
-- already finalized (i.e. it never received a terminal @stop_reason@), emit
-- it now as a finalized 'ProseTurn'.  If the turn was already finalized it
-- was already emitted on the earlier tick — do NOT re-emit it (avoid a
-- duplicate finalized emission of the same turn id).
--
-- If the content is solely @tool_result@ blocks, we treat it as a tool-call
-- return and leave the current turn open.
handleUser :: KeyMap Value -> ProseState -> (ProseState, Maybe ProseTurn)
handleUser obj ps =
  case lookupObject "message" obj of
    Nothing  -> noChange ps
    Just msg ->
      if isSolelyToolResult msg
        then noChange ps          -- tool-call return — do not end the turn
        else                      -- real user msg — end turn, backstop finalize
          let ps' = ps { _ps_turn = Nothing }
              emit = case _ps_turn ps of
                Nothing -> Nothing
                Just at ->
                  if T.null (_at_text at) || _at_finalized at
                    then Nothing   -- empty, or already finalized on an earlier tick
                    else Just ProseTurn
                           { _pt_sourceUuid = _at_sourceUuid at
                           , _pt_text       = _at_text at
                           , _pt_finalized  = True
                           }
          in  (ps', emit)

-- | True iff every block in @message.content@ has @type = "tool_result"@.
-- An empty block array or non-array content is treated as NOT solely
-- tool_result (safe fallback — treat as a real user message).
isSolelyToolResult :: KeyMap Value -> Bool
isSolelyToolResult msg =
  case KeyMap.lookup (Key.fromText "content") msg of
    Just (Array blocks) ->
      not (V.null blocks) && V.all isToolResultBlock blocks
    _ -> False

-- | True iff a content block has @type = "tool_result"@.
isToolResultBlock :: Value -> Bool
isToolResultBlock (Object km) = lookupText "type" km == Just "tool_result"
isToolResultBlock _           = False

-- ---------------------------------------------------------------------------
-- Deterministic namespaced turn-id
-- ---------------------------------------------------------------------------

-- | Derive a stable, collision-free UUIDv5 turn identifier.
--
-- @deriveTurnId sessionId firstAssistantUuid@ hashes the namespaced bytes
-- @sessionId ++ \":\" ++ firstAssistantUuid@ under the DNS namespace UUID,
-- producing a deterministic Text that is:
--
--   * stable across the lifetime of a turn (first-assistant uuid is
--     pinned and never changes);
--   * distinct across sessions (namespace includes @sessionId@);
--   * reproducible after a crash\/restart (same inputs → same output).
deriveTurnId :: Text -> Text -> Text
deriveTurnId sessionId firstUuid =
  UUID.toText (V5.generateNamed V5.namespaceDNS nameBytes)
  where
    nameBytes :: [Word8]
    nameBytes = BS.unpack (TE.encodeUtf8 (sessionId <> ":" <> firstUuid))
