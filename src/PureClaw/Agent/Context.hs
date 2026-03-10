module PureClaw.Agent.Context
  ( -- * Context type (constructor intentionally NOT exported)
    Context
    -- * Construction
  , emptyContext
    -- * Operations
  , addMessage
  , contextMessages
  , contextSystemPrompt
    -- * Token tracking
  , estimateTokens
  , estimateBlockTokens
  , estimateMessageTokens
  , contextTokenEstimate
    -- * Usage tracking
  , recordUsage
  , contextTotalInputTokens
  , contextTotalOutputTokens
    -- * Context management
  , contextMessageCount
  , replaceMessages
  , clearMessages
  ) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Providers.Class

-- | Conversation context. Maintains message history, an optional
-- system prompt, and cumulative token usage. Constructor is not
-- exported — use 'emptyContext'.
data Context = Context
  { _ctx_systemPrompt     :: Maybe Text
  , _ctx_messages         :: [Message]  -- oldest first
  , _ctx_totalInputTokens :: !Int
  , _ctx_totalOutputTokens :: !Int
  }
  deriving stock (Show, Eq)

-- | Create an empty context with an optional system prompt.
emptyContext :: Maybe Text -> Context
emptyContext sys = Context sys [] 0 0

-- | Append a message to the conversation history.
addMessage :: Message -> Context -> Context
addMessage msg ctx = ctx { _ctx_messages = _ctx_messages ctx ++ [msg] }

-- | Get all messages in chronological order.
contextMessages :: Context -> [Message]
contextMessages = _ctx_messages

-- | Get the system prompt, if any.
contextSystemPrompt :: Context -> Maybe Text
contextSystemPrompt = _ctx_systemPrompt

-- Token estimation (approximate: ~4 characters per token for mixed
-- English text and code). Used for context window management — the
-- provider returns actual usage after each completion.

-- | Estimate token count for a text string.
-- Uses the ~4 characters per token heuristic.
estimateTokens :: Text -> Int
estimateTokens t
  | T.null t  = 0
  | otherwise = max 1 (T.length t `div` 4)

-- | Estimate token count for a content block.
estimateBlockTokens :: ContentBlock -> Int
estimateBlockTokens (TextBlock t) = estimateTokens t
estimateBlockTokens (ToolUseBlock _ name input) =
  estimateTokens name + fromIntegral (BL.length (encode input) `div` 4)
estimateBlockTokens (ToolResultBlock _ content _) = estimateTokens content

-- | Estimate token count for a message.
estimateMessageTokens :: Message -> Int
estimateMessageTokens msg =
  4 + sum (map estimateBlockTokens (_msg_content msg))
  -- 4 tokens overhead per message for role, delimiters

-- | Estimate total token count of the current context window.
-- Includes system prompt and all messages.
contextTokenEstimate :: Context -> Int
contextTokenEstimate ctx =
  let sysTokens = maybe 0 estimateTokens (_ctx_systemPrompt ctx)
      msgTokens = sum (map estimateMessageTokens (_ctx_messages ctx))
  in sysTokens + msgTokens

-- Usage tracking — records actual provider-reported token usage.

-- | Record usage from a provider response.
recordUsage :: Maybe Usage -> Context -> Context
recordUsage Nothing ctx = ctx
recordUsage (Just usage) ctx = ctx
  { _ctx_totalInputTokens = _ctx_totalInputTokens ctx + _usage_inputTokens usage
  , _ctx_totalOutputTokens = _ctx_totalOutputTokens ctx + _usage_outputTokens usage
  }

-- | Get total input tokens consumed (from provider reports).
contextTotalInputTokens :: Context -> Int
contextTotalInputTokens = _ctx_totalInputTokens

-- | Get total output tokens consumed (from provider reports).
contextTotalOutputTokens :: Context -> Int
contextTotalOutputTokens = _ctx_totalOutputTokens

-- Context management — for compaction and session reset.

-- | Get the number of messages in the context.
contextMessageCount :: Context -> Int
contextMessageCount = length . _ctx_messages

-- | Replace all messages with a new list. Used by compaction to
-- swap old messages for a summary.
replaceMessages :: [Message] -> Context -> Context
replaceMessages msgs ctx = ctx { _ctx_messages = msgs }

-- | Clear all messages (keep system prompt and usage counters).
-- Used by @/new@ to start a fresh session.
clearMessages :: Context -> Context
clearMessages ctx = ctx { _ctx_messages = [] }
