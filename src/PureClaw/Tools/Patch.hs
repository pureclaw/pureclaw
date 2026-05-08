module PureClaw.Tools.Patch
  ( -- * Tool registration
    patchTool
    -- * Internals (exported for testing)
  , parsePatch
  , PatchHunk (..)
  , PatchFile (..)
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Security.Path
import PureClaw.Tools.Registry

-- | A single hunk within a patch file.
data PatchHunk = PatchHunk
  { _ph_removals :: [Text]
    -- ^ Lines to remove (without the '-' prefix)
  , _ph_additions :: [Text]
    -- ^ Lines to add (without the '+' prefix)
  , _ph_context :: [Text]
    -- ^ Context lines (without the ' ' prefix) preceding the change
  }
  deriving stock (Show, Eq)

-- | A patch for a single file, possibly containing multiple hunks.
data PatchFile = PatchFile
  { _pf_path  :: Text
    -- ^ File path (relative to workspace root)
  , _pf_hunks :: [PatchHunk]
  }
  deriving stock (Show, Eq)

-- | Create a patch tool that applies unified-diff-style patches
-- to one or more files in a single tool call.
patchTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, ToolHandler)
patchTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "patch"
      , _td_description = T.unlines
          [ "Apply a multi-file patch in unified diff format."
          , "Accepts a patch string containing one or more file diffs."
          , "Format:"
          , "  --- a/path/to/file"
          , "  +++ b/path/to/file"
          , "  @@ ... @@"
          , "  -removed line"
          , "  +added line"
          , "   context line"
          , "Multiple files can be patched in a single call."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "patch" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The patch in unified diff format" :: Text)
                  ]
              ]
          , "required" .= (["patch"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right patchText ->
          case parsePatch patchText of
            Left err -> pure ("Patch parse error: " <> err, True)
            Right [] -> pure ("Empty patch — no files to modify", True)
            Right files -> applyPatch files

    applyPatch :: [PatchFile] -> IO (Text, Bool)
    applyPatch files = do
      results <- mapM applyFile files
      let (successes, failures) = partitionResults results
      if null failures
        then pure (T.intercalate "\n" successes, False)
        else pure (T.intercalate "\n" (successes <> failures), True)

    applyFile :: PatchFile -> IO (Either Text Text)
    applyFile pf = do
      let path = _pf_path pf
      pathResult <- mkSafePath root (T.unpack path)
      case pathResult of
        Left pe -> pure (Left (path <> ": " <> T.pack (show pe)))
        Right sp -> do
          readResult <- try @SomeException (_fh_readFile fh sp)
          case readResult of
            Left e -> pure (Left (path <> ": " <> T.pack (show e)))
            Right bs -> case TE.decodeUtf8' bs of
              Left _ -> pure (Left (path <> ": cannot patch binary file"))
              Right content -> do
                case applyHunks content (_pf_hunks pf) of
                  Left err -> pure (Left (path <> ": " <> err))
                  Right newContent -> do
                    writeResult <- try @SomeException
                      (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
                    case writeResult of
                      Left e -> pure (Left (path <> ": " <> T.pack (show e)))
                      Right () -> pure (Right ("Patched " <> path))

    partitionResults :: [Either Text Text] -> ([Text], [Text])
    partitionResults = foldr go ([], [])
      where
        go (Right s) (ss, fs) = (s:ss, fs)
        go (Left  f) (ss, fs) = (ss, f:fs)

    parseInput :: Value -> Parser Text
    parseInput = withObject "PatchInput" $ \o -> o .: "patch"

-- | Apply a list of hunks to file content, sequentially.
applyHunks :: Text -> [PatchHunk] -> Either Text Text
applyHunks content [] = Right content
applyHunks content (h:hs) =
  case applyHunk content h of
    Left err -> Left err
    Right content' -> applyHunks content' hs

-- | Apply a single hunk to file content.
-- Uses context lines to locate the position, then removes the
-- specified lines and inserts the additions.
applyHunk :: Text -> PatchHunk -> Either Text Text
applyHunk content hunk =
  let contentLines = T.lines content
      -- Build the pattern: context lines followed by removal lines
      pattern = _ph_context hunk <> _ph_removals hunk
  in case findPattern pattern contentLines of
    Nothing ->
      -- Try without context (just removals)
      case findPattern (_ph_removals hunk) contentLines of
        Nothing -> Left ("hunk failed: could not find target lines")
        Just idx ->
          let before = take idx contentLines
              after  = drop (idx + length (_ph_removals hunk)) contentLines
              result = before <> _ph_additions hunk <> after
          in Right (T.unlines result)
    Just idx ->
      let ctxLen = length (_ph_context hunk)
          removeLen = length (_ph_removals hunk)
          before = take (idx + ctxLen) contentLines  -- keep context
          after  = drop (idx + ctxLen + removeLen) contentLines
          result = before <> _ph_additions hunk <> after
      in Right (T.unlines result)

-- | Find the starting index of a pattern (list of lines) within
-- the content lines. Returns the index of the first match.
findPattern :: [Text] -> [Text] -> Maybe Int
findPattern [] _ = Just 0
findPattern _ [] = Nothing
findPattern pattern contentLines = go 0 contentLines
  where
    patLen = length pattern
    go _ remaining | length remaining < patLen = Nothing
    go idx remaining
      | take patLen remaining `linesMatch` pattern = Just idx
      | otherwise = go (idx + 1) (drop 1 remaining)

    linesMatch :: [Text] -> [Text] -> Bool
    linesMatch as bs = length as == length bs && all (uncurry matchLine) (zip as bs)

    matchLine :: Text -> Text -> Bool
    matchLine a b = T.strip a == T.strip b

-- | Parse a unified diff into a list of 'PatchFile'.
parsePatch :: Text -> Either Text [PatchFile]
parsePatch input =
  let ls = T.lines input
  in parseFiles ls

parseFiles :: [Text] -> Either Text [PatchFile]
parseFiles [] = Right []
parseFiles ls =
  case dropWhile (not . isFileLine) ls of
    [] -> Right []
    rest ->
      case parseOneFile rest of
        Left err -> Left err
        Right (pf, remaining) -> do
          more <- parseFiles remaining
          Right (pf : more)

isFileLine :: Text -> Bool
isFileLine l = "--- " `T.isPrefixOf` l

parseOneFile :: [Text] -> Either Text (PatchFile, [Text])
parseOneFile [] = Left "unexpected end of patch"
parseOneFile (_minusLine:rest) =
  case rest of
    [] -> Left "missing +++ line after ---"
    (plusLine:rest') ->
      let path = extractPath plusLine
      in case parseHunks rest' of
        (hunks, remaining) -> Right (PatchFile path hunks, remaining)

extractPath :: Text -> Text
extractPath line =
  let stripped = T.strip line
      -- Remove "+++ " or "--- " prefix
      withoutPrefix = T.drop 4 stripped
      -- Remove "a/" or "b/" prefix if present
  in if "a/" `T.isPrefixOf` withoutPrefix || "b/" `T.isPrefixOf` withoutPrefix
    then T.drop 2 withoutPrefix
    else withoutPrefix

parseHunks :: [Text] -> ([PatchHunk], [Text])
parseHunks [] = ([], [])
parseHunks ls@(l:_)
  | "@@" `T.isPrefixOf` l =
      let (hunk, rest) = parseOneHunk (drop 1 ls)  -- skip @@ line
          (more, remaining) = parseHunks rest
      in (hunk : more, remaining)
  | isFileLine l = ([], ls)  -- next file
  | otherwise = parseHunks (drop 1 ls)  -- skip non-hunk lines

parseOneHunk :: [Text] -> (PatchHunk, [Text])
parseOneHunk = go [] [] []
  where
    go ctx rmv add [] = (PatchHunk rmv add ctx, [])
    go ctx rmv add (l:ls)
      | "@@" `T.isPrefixOf` l = (PatchHunk rmv add ctx, l:ls)  -- next hunk
      | isFileLine l          = (PatchHunk rmv add ctx, l:ls)  -- next file
      | "-" `T.isPrefixOf` l && not ("---" `T.isPrefixOf` l) =
          go ctx (rmv <> [T.drop 1 l]) add ls
      | "+" `T.isPrefixOf` l && not ("+++" `T.isPrefixOf` l) =
          go ctx rmv (add <> [T.drop 1 l]) ls
      | " " `T.isPrefixOf` l =
          if null rmv && null add
            then go (ctx <> [T.drop 1 l]) rmv add ls  -- pre-change context
            else go ctx rmv add ls  -- post-change context (skip)
      | otherwise = go ctx rmv add ls  -- skip other lines
