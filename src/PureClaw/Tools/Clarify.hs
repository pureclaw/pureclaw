module PureClaw.Tools.Clarify
  ( -- * Tool registration
    clarifyTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a clarify tool that lets the agent ask the user structured questions.
-- Supports open-ended questions and multiple choice (up to 4 options).
clarifyTool :: ChannelHandle -> (ToolDefinition, ToolHandler)
clarifyTool ch = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "clarify"
      , _td_description = T.unlines
          [ "Ask the user a clarifying question. Use when the request is ambiguous"
          , "or you need more information before proceeding."
          , "Supports open-ended questions (just question) or multiple choice"
          , "(question + choices array, max 4 options)."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "question" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The question to ask the user" :: Text)
                  ]
              , "choices" .= object
                  [ "type" .= ("array" :: Text)
                  , "items" .= object [ "type" .= ("string" :: Text) ]
                  , "maxItems" .= (4 :: Int)
                  , "description" .= ("Optional: up to 4 multiple-choice options" :: Text)
                  ]
              ]
          , "required" .= (["question"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseClarifyInput input of
        Left err -> pure (T.pack err, True)
        Right ci -> askUser ci

    askUser :: ClarifyInput -> IO (Text, Bool)
    askUser ci = do
      let prompt = formatPrompt (_ci_question ci) (_ci_choices ci)
      result <- try @SomeException (_ch_prompt ch prompt)
      case result of
        Left e -> pure ("Failed to get user response: " <> T.pack (show e), True)
        Right response -> do
          let resolved = resolveChoice response (_ci_choices ci)
          pure (encodeResponse (_ci_question ci) (_ci_choices ci) resolved, False)

    formatPrompt :: Text -> Maybe [Text] -> Text
    formatPrompt question Nothing = question <> "\n> "
    formatPrompt question (Just choices) =
      let numbered = zipWith (\i c -> T.pack (show (i :: Int)) <> ". " <> c) [1..] choices
      in question <> "\n" <> T.unlines numbered <> T.pack (show (length choices + 1)) <> ". Other\n> "

    resolveChoice :: Text -> Maybe [Text] -> Text
    resolveChoice response Nothing = response
    resolveChoice response (Just choices) =
      case reads (T.unpack (T.strip response)) :: [(Int, String)] of
        [(n, "")] | n >= 1 && n <= length choices -> choices !! (n - 1)
                  | n == length choices + 1        -> response  -- "Other" selected
                  | otherwise                      -> response  -- out of range, treat as freeform
        _                                          -> response  -- non-numeric, treat as freeform

    encodeResponse :: Text -> Maybe [Text] -> Text -> Text
    encodeResponse question choices answer =
      let result = object $
            [ "question" .= question
            , "user_response" .= answer
            ] <> maybe [] (\cs -> ["choices_offered" .= cs]) choices
      in case encode result of
        bs -> TE.decodeUtf8Lenient (toStrictBS bs)

    toStrictBS :: BL.ByteString -> BS.ByteString
    toStrictBS = BL.toStrict

data ClarifyInput = ClarifyInput
  { _ci_question :: Text
  , _ci_choices  :: Maybe [Text]
  }

parseClarifyInput :: Value -> Parser ClarifyInput
parseClarifyInput = withObject "ClarifyInput" $ \o ->
  ClarifyInput
    <$> o .:  "question"
    <*> o .:? "choices"
