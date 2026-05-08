module PureClaw.Tools.SearchFiles
  ( -- * Tool registration
    searchFilesTool
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit
import System.IO.Error (isDoesNotExistError)
import System.Process.Typed qualified as P

import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a search_files tool backed by ripgrep.
-- This tool does NOT go through SecurityPolicy because it is a read-only
-- internal capability — the agent cannot use it to execute arbitrary commands.
searchFilesTool :: WorkspaceRoot -> (ToolDefinition, ToolHandler)
searchFilesTool (WorkspaceRoot root) = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "search_files"
      , _td_description = T.unlines
          [ "Search file contents or file names using ripgrep."
          , "Modes:"
          , "  content (default) — regex search over file contents, returns matching lines with line numbers"
          , "  files_only — return only file paths matching the pattern or glob"
          , "  count — return match counts per file"
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "pattern" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Regex pattern to search for (ripgrep syntax)" :: Text)
                  ]
              , "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Directory or file to search in, relative to workspace root (default: \".\")" :: Text)
                  ]
              , "file_glob" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Glob filter for file names, e.g. \"*.hs\" or \"*.{ts,tsx}\"" :: Text)
                  ]
              , "output_mode" .= object
                  [ "type" .= ("string" :: Text)
                  , "enum" .= (["content", "files_only", "count"] :: [Text])
                  , "description" .= ("Output mode (default: content)" :: Text)
                  ]
              , "context" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Number of context lines before and after each match (default: 0)" :: Text)
                  ]
              , "limit" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Maximum number of matches to return (default: 50)" :: Text)
                  ]
              , "case_insensitive" .= object
                  [ "type" .= ("boolean" :: Text)
                  , "description" .= ("Case-insensitive search (default: false)" :: Text)
                  ]
              ]
          , "required" .= (["pattern"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right si -> runSearch si

    runSearch :: SearchInput -> IO (Text, Bool)
    runSearch si = do
      let args = buildRgArgs si
          config = P.setWorkingDir root
                 $ P.proc "rg" args
      result <- try @IOException $ P.readProcess config
      case result of
        Left e
          | isDoesNotExistError e ->
              pure ("search_files requires ripgrep (rg) but it is not installed or not on PATH", True)
          | otherwise ->
              pure ("search_files error: " <> T.pack (show e), True)
        Right (exitCode, outLazy, errLazy) ->
          let out = TE.decodeUtf8Lenient (BL.toStrict outLazy)
              err = TE.decodeUtf8Lenient (BL.toStrict errLazy)
          in case exitCode of
            ExitSuccess   -> pure (truncateOutput out, False)
            ExitFailure 1 -> pure ("No matches found", False)  -- rg returns 1 for no matches
            ExitFailure _ -> pure ("search_files error: " <> err, True)

    truncateOutput :: Text -> Text
    truncateOutput t
      | T.length t > 100000 =
          T.take 100000 t <> "\n[...output truncated at 100000 chars]"
      | otherwise = t

    buildRgArgs :: SearchInput -> [String]
    buildRgArgs si =
      let modeArgs = case _si_outputMode si of
            "files_only" -> ["--files-with-matches"]
            "count"      -> ["--count"]
            _            -> ["--line-number"]  -- content mode (default)
          globArgs = case _si_fileGlob si of
            Nothing -> []
            Just g  -> ["--glob", T.unpack g]
          ctxArgs = case _si_context si of
            Nothing -> []
            Just n  -> ["--context", show n]
          limitArgs = ["--max-count", show (_si_limit si)]
          caseArgs = ["--ignore-case" | _si_caseInsensitive si]
          searchPath = T.unpack (_si_path si)
      in concat
          [ ["--no-heading", "--color", "never"]
          , modeArgs
          , globArgs
          , ctxArgs
          , limitArgs
          , caseArgs
          , ["--", T.unpack (_si_pattern si), searchPath]
          ]

data SearchInput = SearchInput
  { _si_pattern         :: Text
  , _si_path            :: Text
  , _si_fileGlob        :: Maybe Text
  , _si_outputMode      :: Text
  , _si_context         :: Maybe Int
  , _si_limit           :: Int
  , _si_caseInsensitive :: Bool
  }

parseInput :: Value -> Parser SearchInput
parseInput = withObject "SearchFilesInput" $ \o ->
  SearchInput
    <$> o .:  "pattern"
    <*> o .:? "path"             .!= "."
    <*> o .:? "file_glob"
    <*> o .:? "output_mode"      .!= "content"
    <*> o .:? "context"
    <*> o .:? "limit"            .!= 50
    <*> o .:? "case_insensitive" .!= False
