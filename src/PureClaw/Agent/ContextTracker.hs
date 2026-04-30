module PureClaw.Agent.ContextTracker
  ( -- * Context status snapshot
    ContextStatus (..)
  , contextStatus
    -- * Model context windows
  , contextWindowForModel
  , defaultContextWindow
    -- * Utilization queries
  , isContextHigh
  , highUtilizationThreshold
    -- * Formatting
  , formatContextStatus
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context
import PureClaw.Core.Types

-- | Snapshot of current context tracking state. Produced from a
-- 'Context' and a 'ModelId' — purely computed, no IO.
data ContextStatus = ContextStatus
  { _cs_estimatedTokens  :: !Int
    -- ^ Heuristic estimate of tokens in the current context window.
  , _cs_contextWindow    :: !Int
    -- ^ Maximum context window size for the active model.
  , _cs_messageCount     :: !Int
    -- ^ Number of messages in the conversation.
  , _cs_utilizationPct   :: !Double
    -- ^ Estimated tokens / context window, as a fraction (0.0–1.0).
  , _cs_totalInputTokens :: !Int
    -- ^ Cumulative input tokens reported by the provider.
  , _cs_totalOutputTokens :: !Int
    -- ^ Cumulative output tokens reported by the provider.
  }
  deriving stock (Show, Eq)

-- | Compute a context status snapshot from the current model and context.
contextStatus :: ModelId -> Context -> ContextStatus
contextStatus model ctx =
  let window    = contextWindowForModel model
      estimated = contextTokenEstimate ctx
      pct       = if window > 0
                  then fromIntegral estimated / fromIntegral window
                  else 0.0
  in ContextStatus
    { _cs_estimatedTokens   = estimated
    , _cs_contextWindow     = window
    , _cs_messageCount      = contextMessageCount ctx
    , _cs_utilizationPct    = pct
    , _cs_totalInputTokens  = contextTotalInputTokens ctx
    , _cs_totalOutputTokens = contextTotalOutputTokens ctx
    }

-- | Look up the context window size for a model. Uses prefix matching
-- against known model families, falling back to 'defaultContextWindow'.
contextWindowForModel :: ModelId -> Int
contextWindowForModel (ModelId mid) = go knownModels
  where
    go [] = defaultContextWindow
    go ((prefix, window):rest)
      | prefix `T.isPrefixOf` mid = window
      | otherwise = go rest

-- | Default context window for unknown models (128k — conservative).
defaultContextWindow :: Int
defaultContextWindow = 128000

-- | Known model families and their context window sizes.
knownModels :: [(Text, Int)]
knownModels =
  -- Anthropic Claude
  [ ("claude-opus-4",          200000)
  , ("claude-sonnet-4",        200000)
  , ("claude-3-7-sonnet",      200000)
  , ("claude-3-5-sonnet",      200000)
  , ("claude-3-5-haiku",       200000)
  , ("claude-3-opus",          200000)
  , ("claude-3-sonnet",        200000)
  , ("claude-3-haiku",         200000)
  -- OpenAI
  , ("gpt-4o",                 128000)
  , ("gpt-4-turbo",            128000)
  , ("gpt-4-0125",             128000)
  , ("gpt-4-1106",             128000)
  , ("gpt-4",                    8192)
  , ("gpt-3.5-turbo",          16385)
  , ("o1",                     200000)
  , ("o3",                     200000)
  -- Ollama common defaults
  , ("llama3",                   8192)
  , ("mistral",                 32768)
  , ("mixtral",                 32768)
  , ("deepseek",               128000)
  ]

-- | Threshold above which context utilization is considered high (80%).
highUtilizationThreshold :: Double
highUtilizationThreshold = 0.80

-- | Check whether context utilization exceeds the high threshold.
isContextHigh :: ModelId -> Context -> Bool
isContextHigh model ctx =
  let status = contextStatus model ctx
  in _cs_utilizationPct status >= highUtilizationThreshold

-- | Format a context status snapshot as human-readable text for display.
formatContextStatus :: ContextStatus -> Text
formatContextStatus status = T.intercalate "\n"
  [ "Context window: " <> T.pack (show (_cs_estimatedTokens status))
      <> " / " <> T.pack (show (_cs_contextWindow status))
      <> " tokens (" <> T.pack (show (round (100 * _cs_utilizationPct status) :: Int)) <> "%)"
  , "Messages:       " <> T.pack (show (_cs_messageCount status))
  , "Total usage:    " <> T.pack (show (_cs_totalInputTokens status)) <> " in / "
      <> T.pack (show (_cs_totalOutputTokens status)) <> " out"
  ]
