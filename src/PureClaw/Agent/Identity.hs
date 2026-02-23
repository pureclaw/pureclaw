module PureClaw.Agent.Identity
  ( -- * Identity types
    AgentIdentity (..)
  , defaultIdentity
    -- * Loading
  , loadIdentity
  , loadIdentityFromText
    -- * System prompt generation
  , identitySystemPrompt
  ) where

import Data.Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory

-- | Agent identity loaded from a SOUL.md file or configured defaults.
-- Controls the agent's system prompt, personality, and behavioral constraints.
data AgentIdentity = AgentIdentity
  { _ai_name         :: Text
  , _ai_description  :: Text
  , _ai_instructions :: Text
  , _ai_constraints  :: [Text]
  }
  deriving stock (Show, Eq)

-- | A minimal default identity for when no SOUL.md is provided.
defaultIdentity :: AgentIdentity
defaultIdentity = AgentIdentity
  { _ai_name         = "PureClaw"
  , _ai_description  = "A helpful AI assistant."
  , _ai_instructions = ""
  , _ai_constraints  = []
  }

-- | Load an identity from a SOUL.md file at the given path.
-- Returns 'defaultIdentity' if the file does not exist.
loadIdentity :: FilePath -> IO AgentIdentity
loadIdentity path = do
  exists <- doesFileExist path
  if exists
    then do
      content <- TIO.readFile path
      pure (loadIdentityFromText content)
    else pure defaultIdentity

-- | Parse identity from SOUL.md markdown content. Extracts sections
-- by heading:
--
-- @
-- # Name
-- Agent name here
--
-- # Description
-- What this agent does.
--
-- # Instructions
-- How the agent should behave.
--
-- # Constraints
-- - Do not do X
-- - Always do Y
-- @
loadIdentityFromText :: Text -> AgentIdentity
loadIdentityFromText content =
  let sections = parseSections content
      get key = fromMaybe "" (lookup key sections)
      constraints = maybe [] parseConstraints (lookup "constraints" sections)
  in AgentIdentity
    { _ai_name         = T.strip (get "name")
    , _ai_description  = T.strip (get "description")
    , _ai_instructions = T.strip (get "instructions")
    , _ai_constraints  = constraints
    }

-- | Generate a system prompt from an identity.
identitySystemPrompt :: AgentIdentity -> Text
identitySystemPrompt ident =
  let parts = filter (not . T.null)
        [ if T.null (_ai_name ident)
            then ""
            else "You are " <> _ai_name ident <> "."
        , _ai_description ident
        , _ai_instructions ident
        , if null (_ai_constraints ident)
            then ""
            else "Constraints:\n" <> T.unlines (map ("- " <>) (_ai_constraints ident))
        ]
  in T.intercalate "\n\n" parts

-- | Parse markdown into sections keyed by lowercase heading text.
-- Lines before the first heading are ignored.
parseSections :: Text -> [(Text, Text)]
parseSections content =
  let ls = T.lines content
  in go Nothing [] ls []
  where
    go :: Maybe Text -> [Text] -> [Text] -> [(Text, Text)] -> [(Text, Text)]
    go currentKey accLines [] result =
      case currentKey of
        Nothing -> result
        Just k  -> result ++ [(k, T.unlines (reverse accLines))]
    go currentKey accLines (l:rest) result
      | Just heading <- parseHeading l =
          let result' = case currentKey of
                Nothing -> result
                Just k  -> result ++ [(k, T.unlines (reverse accLines))]
          in go (Just (T.toLower heading)) [] rest result'
      | otherwise = go currentKey (l : accLines) rest result

    parseHeading :: Text -> Maybe Text
    parseHeading line =
      let stripped = T.stripStart line
      in if T.isPrefixOf "# " stripped
         then Just (T.strip (T.drop 2 stripped))
         else Nothing

-- | Parse constraint lines from a markdown list.
-- Each line starting with @-@ is a constraint.
parseConstraints :: Text -> [Text]
parseConstraints content =
  [ T.strip (T.drop 1 line)
  | line <- T.lines content
  , let trimmed = T.stripStart line
  , T.isPrefixOf "- " trimmed
  ]
