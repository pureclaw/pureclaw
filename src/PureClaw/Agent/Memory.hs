module PureClaw.Agent.Memory
  ( -- * Memory integration
    autoRecall
  , autoSave
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Data.Map.Strict qualified as Map

import PureClaw.Core.Types
import PureClaw.Handles.Log
import PureClaw.Handles.Memory

-- | Minimum message length to trigger auto-save (characters).
minSaveLength :: Int
minSaveLength = 50

-- | Automatically recall relevant memories for a user message.
-- Returns formatted context to prepend to the system prompt, or
-- Nothing if no relevant memories are found.
autoRecall :: MemoryHandle -> LogHandle -> Text -> IO (Maybe Text)
autoRecall mh logger query = do
  results <- _mh_search mh query defaultSearchConfig { _sc_maxResults = 3 }
  if null results
    then pure Nothing
    else do
      _lh_logDebug logger $ "Recalled " <> T.pack (show (length results)) <> " memories"
      let formatted = T.unlines
            [ "## Relevant memories"
            , ""
            , T.intercalate "\n\n" [ _sr_content r | r <- results ]
            ]
      pure (Just formatted)

-- | Automatically save an assistant response to memory if it's
-- long enough to be worth remembering.
autoSave :: MemoryHandle -> LogHandle -> Text -> IO ()
autoSave mh logger content
  | T.length content < minSaveLength = pure ()
  | otherwise = do
      let source = MemorySource
            { _ms_content  = content
            , _ms_metadata = Map.empty
            }
      result <- _mh_save mh source
      case result of
        Nothing -> pure ()
        Just mid -> _lh_logDebug logger $ "Auto-saved memory: " <> unMemoryId mid
