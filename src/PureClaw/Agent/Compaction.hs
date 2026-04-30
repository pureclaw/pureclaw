module PureClaw.Agent.Compaction
  ( -- * Compaction
    compactContext
  , CompactionResult (..)
    -- * Configuration
  , defaultTokenLimit
  , defaultKeepRecent
    -- * Metadata
  , compactionMetadataKey
  ) where

import Control.Exception
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context
import PureClaw.Core.Types
import PureClaw.Providers.Class

-- | Result of a compaction attempt.
data CompactionResult
  = Compacted Int Int Text  -- ^ old count, new count, summary text
  | NotNeeded               -- ^ context is below threshold
  | CompactionError Text    -- ^ provider error during summarization
  deriving stock (Show, Eq)

-- | Metadata key used to mark compaction entries in the transcript.
-- 'loadRecentMessages' looks for the last entry carrying this key and
-- only replays entries from that point forward.
compactionMetadataKey :: Text
compactionMetadataKey = "compaction"

-- | Default context window token limit (200k for Claude).
defaultTokenLimit :: Int
defaultTokenLimit = 200000

-- | Default number of recent messages to keep uncompacted.
defaultKeepRecent :: Int
defaultKeepRecent = 10

-- | Compact a context by summarizing old messages via the provider.
--
-- Keeps the most recent @keepRecent@ messages intact and asks the
-- provider to summarize the older ones into a single message. The
-- summary replaces the old messages in the context.
--
-- Returns 'NotNeeded' if the context is below the token threshold.
compactContext
  :: Provider p
  => p
  -> ModelId
  -> Int        -- ^ token threshold (compact when estimated tokens exceed this)
  -> Int        -- ^ number of recent messages to keep
  -> Context
  -> IO (Context, CompactionResult)
compactContext provider model threshold keepRecent ctx
  | contextTokenEstimate ctx < threshold = pure (ctx, NotNeeded)
  | contextMessageCount ctx <= keepRecent = pure (ctx, NotNeeded)
  | otherwise = do
      let msgs = contextMessages ctx
          oldCount = length msgs - keepRecent
          (oldMsgs, recentMsgs) = splitAt oldCount msgs
          summaryPrompt = buildSummaryPrompt oldMsgs
      summaryResult <- summarize provider model summaryPrompt
      case summaryResult of
        Left err -> pure (ctx, CompactionError err)
        Right summaryText ->
          let prefixed = "[Context summary] " <> summaryText
              summaryMsg = textMessage User prefixed
              newMsgs = summaryMsg : recentMsgs
              ctx' = replaceMessages newMsgs ctx
          in pure (ctx', Compacted (length msgs) (length newMsgs) prefixed)

-- | Build a prompt asking the provider to summarize conversation history.
buildSummaryPrompt :: [Message] -> Text
buildSummaryPrompt msgs =
  "Summarize the following conversation history concisely. "
  <> "Preserve key facts, decisions, file paths, and context needed "
  <> "to continue the conversation. Be brief but complete.\n\n"
  <> T.intercalate "\n\n" (map formatMessage msgs)

-- | Format a message for the summary prompt.
formatMessage :: Message -> Text
formatMessage msg =
  let role = case _msg_role msg of
        User      -> "User"
        Assistant -> "Assistant"
      content = T.intercalate " " [extractText b | b <- _msg_content msg]
  in role <> ": " <> content

-- | Extract text content from a block.
extractText :: ContentBlock -> Text
extractText (TextBlock t) = t
extractText (ToolUseBlock _ name _) = "[tool:" <> name <> "]"
extractText (ImageBlock mediaType _) = "[image:" <> mediaType <> "]"
extractText (ToolResultBlock _ parts _) = "[result:" <> T.take 100 (partsText parts) <> "]"

-- | Extract text from tool result parts.
partsText :: [ToolResultPart] -> Text
partsText ps = T.intercalate " " [t | TRPText t <- ps]

-- | Call the provider to generate a summary.
summarize :: Provider p => p -> ModelId -> Text -> IO (Either Text Text)
summarize provider model prompt = do
  let req = CompletionRequest
        { _cr_model        = model
        , _cr_messages     = [textMessage User prompt]
        , _cr_systemPrompt = Just "You are a conversation summarizer. Produce a concise summary."
        , _cr_maxTokens    = Just 1024
        , _cr_tools        = []
        , _cr_toolChoice   = Nothing
        }
  result <- try @SomeException (complete provider req)
  case result of
    Left e -> pure (Left (T.pack (show e)))
    Right resp ->
      let text = responseText resp
      in if T.null (T.strip text)
           then pure (Left "Provider returned empty summary")
           else pure (Right text)
