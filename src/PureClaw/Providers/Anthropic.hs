module PureClaw.Providers.Anthropic
  ( -- * Provider type (constructor intentionally NOT exported)
    AnthropicProvider
  , mkAnthropicProvider
    -- * Errors
  , AnthropicError (..)
    -- * Request/response encoding (exported for testing)
  , encodeRequest
  , decodeResponse
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Security.Secrets

-- | Anthropic API provider. Constructor is not exported — use
-- 'mkAnthropicProvider'.
data AnthropicProvider = AnthropicProvider
  { _ap_manager :: HTTP.Manager
  , _ap_apiKey  :: ApiKey
  }

-- | Create an Anthropic provider with an HTTP manager and API key.
mkAnthropicProvider :: HTTP.Manager -> ApiKey -> AnthropicProvider
mkAnthropicProvider = AnthropicProvider

instance Provider AnthropicProvider where
  complete = anthropicComplete

-- | Errors from the Anthropic API.
data AnthropicError
  = AnthropicAPIError Int ByteString   -- ^ HTTP status code + response body
  | AnthropicParseError Text           -- ^ JSON parse/decode error
  deriving stock (Show)

instance Exception AnthropicError

instance ToPublicError AnthropicError where
  toPublicError (AnthropicAPIError 429 _) = RateLimitError
  toPublicError (AnthropicAPIError 401 _) = NotAllowedError
  toPublicError _                         = TemporaryError "Provider error"

-- | Anthropic Messages API base URL.
anthropicBaseUrl :: String
anthropicBaseUrl = "https://api.anthropic.com/v1/messages"

-- | Call the Anthropic Messages API.
anthropicComplete :: AnthropicProvider -> CompletionRequest -> IO CompletionResponse
anthropicComplete provider req = do
  initReq <- HTTP.parseRequest anthropicBaseUrl
  let httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (encodeRequest req)
        , HTTP.requestHeaders =
            [ ("x-api-key", withApiKey (_ap_apiKey provider) id)
            , ("anthropic-version", "2023-06-01")
            , ("content-type", "application/json")
            ]
        }
  resp <- HTTP.httpLbs httpReq (_ap_manager provider)
  let status = Status.statusCode (HTTP.responseStatus resp)
  if status /= 200
    then throwIO (AnthropicAPIError status (BL.toStrict (HTTP.responseBody resp)))
    else case decodeResponse (HTTP.responseBody resp) of
      Left err -> throwIO (AnthropicParseError (T.pack err))
      Right response -> pure response

-- | Encode a completion request as JSON for the Anthropic API.
-- System prompts go in the top-level @system@ field, not in the
-- messages array (Anthropic API requirement).
encodeRequest :: CompletionRequest -> BL.ByteString
encodeRequest req = encode $ object $
  [ "model"      .= unModelId (_cr_model req)
  , "max_tokens" .= fromMaybe 4096 (_cr_maxTokens req)
  , "messages"   .= map encodeMsg (_cr_messages req)
  ] ++ maybe [] (\s -> ["system" .= s]) (_cr_systemPrompt req)

encodeMsg :: Message -> Value
encodeMsg msg = object
  [ "role"    .= roleToText (_msg_role msg)
  , "content" .= _msg_content msg
  ]

-- | Decode an Anthropic API response into a 'CompletionResponse'.
decodeResponse :: BL.ByteString -> Either String CompletionResponse
decodeResponse bs = eitherDecode bs >>= parseEither parseResp
  where
    parseResp :: Value -> Parser CompletionResponse
    parseResp = withObject "AnthropicResponse" $ \o -> do
      contentArr <- o .: "content"
      texts <- mapM parseContentBlock contentArr
      modelText <- o .: "model"
      usageObj <- o .: "usage"
      inToks <- usageObj .: "input_tokens"
      outToks <- usageObj .: "output_tokens"
      pure CompletionResponse
        { _crsp_content = T.concat texts
        , _crsp_model   = ModelId modelText
        , _crsp_usage   = Just (Usage inToks outToks)
        }

    parseContentBlock :: Value -> Parser Text
    parseContentBlock = withObject "ContentBlock" $ \b -> do
      bType <- b .: "type"
      if (bType :: Text) == "text"
        then b .: "text"
        else pure ""
