module PureClaw.Tools.Edit
  ( -- * Tool registration
    editTool
    -- * Internals (exported for testing)
  , countOccurrences
  , replaceFirst
  , replaceAll
  , fuzzyFind
  , FuzzyMatch (..)
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

-- | Create an edit tool that performs string replacement in files.
-- Supports exact matching (default), fuzzy matching (fallback when exact
-- match fails), and replace_all mode.
editTool :: WorkspaceRoot -> FileHandle -> (ToolDefinition, ToolHandler)
editTool root fh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "edit"
      , _td_description = T.unlines
          [ "Replace a string in a file. By default, old_string must appear"
          , "exactly once (unique match). Set replace_all to true to replace"
          , "every occurrence. If an exact match fails, fuzzy matching is"
          , "attempted (normalizing whitespace and line endings)."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "path" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The file path relative to the workspace root" :: Text)
                  ]
              , "old_string" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The string to find and replace" :: Text)
                  ]
              , "new_string" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The replacement string" :: Text)
                  ]
              , "replace_all" .= object
                  [ "type" .= ("boolean" :: Text)
                  , "description" .= ("Replace all occurrences instead of requiring a unique match (default: false)" :: Text)
                  ]
              ]
          , "required" .= (["path", "old_string", "new_string"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right ei -> do
          pathResult <- mkSafePath root (T.unpack (_ei_path ei))
          case pathResult of
            Left pe -> pure (T.pack (show pe), True)
            Right sp -> do
              readResult <- try @SomeException (_fh_readFile fh sp)
              case readResult of
                Left e -> pure (T.pack (show e), True)
                Right bs -> case TE.decodeUtf8' bs of
                  Left _ -> pure ("Cannot edit binary file", True)
                  Right content -> applyEdit ei sp content

    applyEdit :: EditInput -> SafePath -> Text -> IO (Text, Bool)
    applyEdit ei sp content
      | _ei_replaceAll ei = doReplaceAll ei sp content
      | otherwise         = doUnique ei sp content

    doReplaceAll :: EditInput -> SafePath -> Text -> IO (Text, Bool)
    doReplaceAll ei sp content = do
      let count = countOccurrences (_ei_oldString ei) content
      if count == 0
        then tryFuzzyReplaceAll ei sp content
        else do
          let newContent = replaceAll (_ei_oldString ei) (_ei_newString ei) content
          writeResult <- try @SomeException
            (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
          case writeResult of
            Left e -> pure (T.pack (show e), True)
            Right () -> pure ("Replaced " <> T.pack (show count) <> " occurrence(s) in " <> _ei_path ei, False)

    doUnique :: EditInput -> SafePath -> Text -> IO (Text, Bool)
    doUnique ei sp content = do
      let count = countOccurrences (_ei_oldString ei) content
      case count of
        0 -> tryFuzzy ei sp content
        1 -> do
          let newContent = replaceFirst (_ei_oldString ei) (_ei_newString ei) content
          writeResult <- try @SomeException
            (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
          case writeResult of
            Left e -> pure (T.pack (show e), True)
            Right () -> pure ("Edited " <> _ei_path ei, False)
        n -> pure ("old_string not unique in " <> _ei_path ei
                   <> " (" <> T.pack (show n) <> " occurrences). Use replace_all: true to replace all.", True)

    tryFuzzy :: EditInput -> SafePath -> Text -> IO (Text, Bool)
    tryFuzzy ei sp content =
      case fuzzyFind (_ei_oldString ei) content of
        NoFuzzyMatch ->
          pure ("old_string not found in " <> _ei_path ei, True)
        AmbiguousFuzzy n strategy ->
          pure ("old_string not unique via " <> strategy <> " matching in " <> _ei_path ei
                <> " (" <> T.pack (show n) <> " occurrences)", True)
        UniqueFuzzy matched strategy -> do
          let newContent = replaceFirst matched (_ei_newString ei) content
          writeResult <- try @SomeException
            (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
          case writeResult of
            Left e -> pure (T.pack (show e), True)
            Right () -> pure ("Edited " <> _ei_path ei <> " (matched via " <> strategy <> ")", False)

    tryFuzzyReplaceAll :: EditInput -> SafePath -> Text -> IO (Text, Bool)
    tryFuzzyReplaceAll ei sp content =
      case fuzzyFind (_ei_oldString ei) content of
        NoFuzzyMatch ->
          pure ("old_string not found in " <> _ei_path ei, True)
        AmbiguousFuzzy n strategy -> do
          -- For replace_all with fuzzy, ambiguous is fine — replace them all
          let matched = fuzzyFindPattern (_ei_oldString ei) strategy
          case matched of
            Nothing -> pure ("old_string not found in " <> _ei_path ei, True)
            Just pat -> do
              let newContent = replaceAll pat (_ei_newString ei) content
              writeResult <- try @SomeException
                (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
              case writeResult of
                Left e -> pure (T.pack (show e), True)
                Right () -> pure ("Replaced " <> T.pack (show n)
                                  <> " occurrence(s) in " <> _ei_path ei
                                  <> " (matched via " <> strategy <> ")", False)
        UniqueFuzzy matched strategy -> do
          let newContent = replaceFirst matched (_ei_newString ei) content
          writeResult <- try @SomeException
            (_fh_writeFile fh sp (TE.encodeUtf8 newContent))
          case writeResult of
            Left e -> pure (T.pack (show e), True)
            Right () -> pure ("Replaced 1 occurrence(s) in " <> _ei_path ei
                              <> " (matched via " <> strategy <> ")", False)

    parseInput :: Value -> Parser EditInput
    parseInput = withObject "EditInput" $ \o ->
      EditInput
        <$> o .:  "path"
        <*> o .:  "old_string"
        <*> o .:  "new_string"
        <*> o .:? "replace_all" .!= False

data EditInput = EditInput
  { _ei_path       :: Text
  , _ei_oldString  :: Text
  , _ei_newString  :: Text
  , _ei_replaceAll :: Bool
  }

-- | Result of a fuzzy search.
data FuzzyMatch
  = NoFuzzyMatch
    -- ^ No match found by any strategy.
  | UniqueFuzzy Text Text
    -- ^ Unique match found. Fields: matched text, strategy name.
  | AmbiguousFuzzy Int Text
    -- ^ Multiple matches found. Fields: count, strategy name.
  deriving stock (Show, Eq)

-- | Try fuzzy matching strategies in priority order.
-- Each strategy normalizes the needle and haystack differently,
-- then searches for the normalized needle in the normalized haystack.
fuzzyFind :: Text -> Text -> FuzzyMatch
fuzzyFind needle haystack = tryStrategies strategies
  where
    strategies =
      [ ("whitespace-normalized", normalizeWhitespace)
      , ("trimmed-lines", trimLines)
      , ("line-ending-normalized", normalizeLineEndings)
      ]

    tryStrategies :: [(Text, Text -> Text)] -> FuzzyMatch
    tryStrategies [] = NoFuzzyMatch
    tryStrategies ((name, normalize):rest) =
      let normNeedle   = normalize needle
          normHaystack = normalize haystack
          count = countOccurrences normNeedle normHaystack
      in case count of
        0 -> tryStrategies rest
        1 -> case findOriginal normalize needle haystack of
          Nothing   -> tryStrategies rest
          Just orig -> UniqueFuzzy orig name
        n -> AmbiguousFuzzy n name

-- | Given a normalization function and the original needle and haystack,
-- find the original text in the haystack that corresponds to the
-- normalized match.
findOriginal :: (Text -> Text) -> Text -> Text -> Maybe Text
findOriginal normalize needle haystack =
  let normNeedle = normalize needle
      normLen = T.length normNeedle
      normH = normalize haystack
      -- Find the position in the normalized haystack
      (before, _) = T.breakOn normNeedle normH
      normPos = T.length before
      -- Map back to original: scan original haystack, tracking
      -- normalized character count to find the start position
  in mapBackToOriginal normalize normPos normLen haystack

-- | Map a position in the normalized text back to the original text.
-- Returns the original substring that normalizes to the match.
mapBackToOriginal :: (Text -> Text) -> Int -> Int -> Text -> Maybe Text
mapBackToOriginal normalize normPos normLen original =
  -- Strategy: try progressively longer substrings at each starting
  -- position until we find one whose normalization contains our match.
  -- This is O(n²) in the worst case but files are bounded in practice.
  let origLen = T.length original
      candidates =
        [ T.take len (T.drop start original)
        | start <- [0..origLen - 1]
        , len   <- [1..origLen - start]
        , let normed = normalize (T.take len (T.drop start original))
        , T.length normed >= normLen
        , let normBefore = normalize (T.take start original)
        , T.length normBefore == normPos
        , normed == T.take normLen (T.drop normPos (normalize original))
        ]
  in case candidates of
    (c:_) -> Just c
    []    -> Nothing

-- | Get the fuzzy pattern text for a strategy (used by replace_all).
fuzzyFindPattern :: Text -> Text -> Maybe Text
fuzzyFindPattern needle strategy =
  let normalize = case strategy of
        "whitespace-normalized" -> normalizeWhitespace
        "trimmed-lines"        -> trimLines
        "line-ending-normalized" -> normalizeLineEndings
        _                      -> id
  in Just (normalize needle)

-- | Normalize all whitespace runs to single spaces, trim.
normalizeWhitespace :: Text -> Text
normalizeWhitespace = T.unwords . T.words

-- | Trim leading/trailing whitespace from each line.
trimLines :: Text -> Text
trimLines = T.unlines . map T.strip . T.lines

-- | Normalize line endings: \r\n → \n
normalizeLineEndings :: Text -> Text
normalizeLineEndings = T.replace "\r\n" "\n"

-- | Count non-overlapping occurrences of a needle in a haystack.
countOccurrences :: Text -> Text -> Int
countOccurrences needle haystack
  | T.null needle = 0
  | otherwise     = go 0 haystack
  where
    go !n remaining =
      case T.breakOn needle remaining of
        (_, after)
          | T.null after -> n
          | otherwise    -> go (n + 1) (T.drop (T.length needle) after)

-- | Replace the first occurrence of needle with replacement.
replaceFirst :: Text -> Text -> Text -> Text
replaceFirst needle replacement haystack =
  let (before, after) = T.breakOn needle haystack
  in before <> replacement <> T.drop (T.length needle) after

-- | Replace all non-overlapping occurrences of needle with replacement.
replaceAll :: Text -> Text -> Text -> Text
replaceAll needle replacement haystack
  | T.null needle = haystack
  | otherwise     = T.intercalate replacement (T.splitOn needle haystack)
