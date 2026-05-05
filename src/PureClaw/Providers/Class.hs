module PureClaw.Providers.Class
  ( -- * Message types
    Role (..)
  , ContentBlock (..)
  , Message (..)
  , roleToText
    -- * Tool result content
  , ToolResultPart (..)
    -- * Convenience constructors
  , textMessage
  , toolResultMessage
    -- * Content block queries
  , responseText
  , toolUseCalls
    -- * Tool definitions
  , ToolDefinition (..)
  , ToolChoice (..)
    -- * Request and response
  , CompletionRequest (..)
  , CompletionResponse (..)
  , Usage (..)
    -- * Streaming
  , StreamEvent (..)
    -- * Provider typeclass
  , Provider (..)
    -- * Existential wrapper
  , SomeProvider (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.Maybe qualified
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Core.Types

-- | Role in a conversation. System prompts are handled separately
-- via 'CompletionRequest._cr_systemPrompt' rather than as messages,
-- since providers differ on how they handle system content.
data Role = User | Assistant
  deriving stock (Show, Eq, Ord)

-- | A single content block within a message. Messages contain one or
-- more content blocks, allowing mixed text and tool interactions.
data ContentBlock
  = TextBlock Text
  | ImageBlock
      { _ib_mediaType :: Text       -- ^ MIME type (e.g. "image/png")
      , _ib_data      :: ByteString -- ^ base64-encoded image data
      }
  | ToolUseBlock
      { _tub_id    :: ToolCallId
      , _tub_name  :: Text
      , _tub_input :: Value
      }
  | ToolResultBlock
      { _trb_toolUseId :: ToolCallId
      , _trb_content   :: [ToolResultPart]
      , _trb_isError   :: Bool
      }
  deriving stock (Show, Eq)

-- | Content within a tool result. Supports text and images so that
-- vision tools can return image data alongside descriptions.
data ToolResultPart
  = TRPText Text
  | TRPImage Text ByteString  -- ^ (mediaType, base64Data)
  deriving stock (Show, Eq)

-- | A single message in a conversation. Content is a list of blocks
-- to support tool use/result interleaving with text.
data Message = Message
  { _msg_role    :: Role
  , _msg_content :: [ContentBlock]
  }
  deriving stock (Show, Eq)

-- | Convert a role to its API text representation.
roleToText :: Role -> Text
roleToText User      = "user"
roleToText Assistant  = "assistant"

-- | Create a simple text message (the common case).
textMessage :: Role -> Text -> Message
textMessage role txt = Message role [TextBlock txt]

-- | Create a tool result message (user role with tool results).
toolResultMessage :: [(ToolCallId, [ToolResultPart], Bool)] -> Message
toolResultMessage results = Message User
  [ ToolResultBlock callId content isErr
  | (callId, content, isErr) <- results
  ]

-- | Extract concatenated text from a response's content blocks.
responseText :: CompletionResponse -> Text
responseText resp =
  let texts = [t | TextBlock t <- _crsp_content resp]
  in T.intercalate "\n" texts

-- | Extract tool use calls from a response's content blocks.
toolUseCalls :: CompletionResponse -> [(ToolCallId, Text, Value)]
toolUseCalls resp =
  [ (_tub_id b, _tub_name b, _tub_input b)
  | b@ToolUseBlock {} <- _crsp_content resp
  ]

-- | Tool definition for offering tools to the provider.
data ToolDefinition = ToolDefinition
  { _td_name        :: Text
  , _td_description :: Text
  , _td_inputSchema :: Value
  }
  deriving stock (Show, Eq)

-- | Tool choice constraint for the provider.
data ToolChoice
  = AutoTool
  | AnyTool
  | SpecificTool Text
  deriving stock (Show, Eq)

-- | Request to an LLM provider.
data CompletionRequest = CompletionRequest
  { _cr_model        :: ModelId
  , _cr_messages     :: [Message]
  , _cr_systemPrompt :: Maybe Text
  , _cr_maxTokens    :: Maybe Int
  , _cr_tools        :: [ToolDefinition]
  , _cr_toolChoice   :: Maybe ToolChoice
  }
  deriving stock (Show, Eq)

-- | Token usage information.
data Usage = Usage
  { _usage_inputTokens  :: Int
  , _usage_outputTokens :: Int
  }
  deriving stock (Show, Eq)

-- | Response from an LLM provider.
data CompletionResponse = CompletionResponse
  { _crsp_content :: [ContentBlock]
  , _crsp_model   :: ModelId
  , _crsp_usage   :: Maybe Usage
  }
  deriving stock (Show, Eq)

-- | Events emitted during streaming completion.
data StreamEvent
  = StreamText Text                -- ^ Partial text content
  | StreamToolUse ToolCallId Text  -- ^ Tool call started (id, name)
  | StreamToolInput Text           -- ^ Partial tool input JSON
  | StreamWarning Text             -- ^ Non-fatal provider-side anomaly (e.g. malformed tool input recovered via fallback). Surfaced so callers can log it.
  | StreamDone CompletionResponse  -- ^ Stream finished with full response
  deriving stock (Show, Eq)

---------------------------------------------------------------------------
-- JSON instances
---------------------------------------------------------------------------

instance ToJSON Role where
  toJSON User      = Aeson.String "user"
  toJSON Assistant  = Aeson.String "assistant"

instance FromJSON Role where
  parseJSON = Aeson.withText "Role" $ \case
    "user"      -> pure User
    "assistant" -> pure Assistant
    other       -> fail ("unknown Role: " <> T.unpack other)

-- | Encode a ByteString as base64 text for JSON.
bsToJSON :: ByteString -> Value
bsToJSON = Aeson.String . TE.decodeUtf8 . B64.encode

-- | Decode base64 text from JSON to a ByteString.
bsFromJSON :: Value -> Aeson.Parser ByteString
bsFromJSON = Aeson.withText "Base64ByteString" $ \t ->
  case B64.decode (TE.encodeUtf8 t) of
    Right bs -> pure bs
    Left err -> fail ("invalid base64: " <> err)

instance ToJSON ToolResultPart where
  toJSON (TRPText t) = Aeson.object
    [ "type" .= ("text" :: Text), "text" .= t ]
  toJSON (TRPImage mt bs) = Aeson.object
    [ "type" .= ("image" :: Text), "media_type" .= mt, "data" .= bsToJSON bs ]

instance FromJSON ToolResultPart where
  parseJSON = Aeson.withObject "ToolResultPart" $ \o -> do
    tag <- o .: "type" :: Aeson.Parser Text
    case tag of
      "text"  -> TRPText <$> o .: "text"
      "image" -> TRPImage <$> o .: "media_type" <*> (o .: "data" >>= bsFromJSON)
      _       -> fail ("unknown ToolResultPart type: " <> T.unpack tag)

instance ToJSON ContentBlock where
  toJSON (TextBlock t) = Aeson.object
    [ "type" .= ("text" :: Text), "text" .= t ]
  toJSON (ImageBlock mt bs) = Aeson.object
    [ "type" .= ("image" :: Text), "media_type" .= mt, "data" .= bsToJSON bs ]
  toJSON (ToolUseBlock callId name input) = Aeson.object
    [ "type" .= ("tool_use" :: Text)
    , "id"   .= unToolCallId callId
    , "name" .= name
    , "input" .= input
    ]
  toJSON (ToolResultBlock callId content isErr) = Aeson.object
    [ "type"        .= ("tool_result" :: Text)
    , "tool_use_id" .= unToolCallId callId
    , "content"     .= content
    , "is_error"    .= isErr
    ]

instance FromJSON ContentBlock where
  parseJSON = Aeson.withObject "ContentBlock" $ \o -> do
    tag <- o .: "type" :: Aeson.Parser Text
    case tag of
      "text" -> TextBlock <$> o .: "text"
      "image" -> ImageBlock <$> o .: "media_type" <*> (o .: "data" >>= bsFromJSON)
      "tool_use" -> (ToolUseBlock . ToolCallId
        <$> (o .: "id"))
        <*> o .: "name"
        <*> o .: "input"
      "tool_result" -> (ToolResultBlock . ToolCallId
        <$> (o .: "tool_use_id"))
        <*> o .: "content"
        <*> o .: "is_error"
      _ -> fail ("unknown ContentBlock type: " <> T.unpack tag)

instance ToJSON Message where
  toJSON (Message role content) = Aeson.object
    [ "role" .= role, "content" .= content ]

instance FromJSON Message where
  parseJSON = Aeson.withObject "Message" $ \o ->
    Message <$> o .: "role" <*> o .: "content"

instance ToJSON ToolDefinition where
  toJSON (ToolDefinition name desc schema) = Aeson.object
    [ "name" .= name, "description" .= desc, "input_schema" .= schema ]

instance FromJSON ToolDefinition where
  parseJSON = Aeson.withObject "ToolDefinition" $ \o ->
    ToolDefinition <$> o .: "name" <*> o .: "description" <*> o .: "input_schema"

instance ToJSON ToolChoice where
  toJSON AutoTool          = Aeson.object [ "type" .= ("auto" :: Text) ]
  toJSON AnyTool           = Aeson.object [ "type" .= ("any" :: Text) ]
  toJSON (SpecificTool t)  = Aeson.object [ "type" .= ("tool" :: Text), "name" .= t ]

instance FromJSON ToolChoice where
  parseJSON = Aeson.withObject "ToolChoice" $ \o -> do
    tag <- o .: "type" :: Aeson.Parser Text
    case tag of
      "auto" -> pure AutoTool
      "any"  -> pure AnyTool
      "tool" -> SpecificTool <$> o .: "name"
      _      -> fail ("unknown ToolChoice type: " <> T.unpack tag)

instance ToJSON Usage where
  toJSON (Usage inp outp) = Aeson.object
    [ "input_tokens" .= inp, "output_tokens" .= outp ]

instance FromJSON Usage where
  parseJSON = Aeson.withObject "Usage" $ \o ->
    Usage <$> o .: "input_tokens" <*> o .: "output_tokens"

instance ToJSON CompletionRequest where
  toJSON req = Aeson.object
    [ "model"         .= unModelId (_cr_model req)
    , "messages"      .= _cr_messages req
    , "system_prompt" .= _cr_systemPrompt req
    , "max_tokens"    .= _cr_maxTokens req
    , "tools"         .= _cr_tools req
    , "tool_choice"   .= _cr_toolChoice req
    ]

instance FromJSON CompletionRequest where
  parseJSON = Aeson.withObject "CompletionRequest" $ \o ->
    (CompletionRequest . ModelId
      <$> (o .: "model"))
      <*> o .: "messages"
      <*> o .:? "system_prompt"
      <*> o .:? "max_tokens"
      <*> (Data.Maybe.fromMaybe [] <$> o .:? "tools")
      <*> o .:? "tool_choice"

instance ToJSON CompletionResponse where
  toJSON resp = Aeson.object
    [ "content" .= _crsp_content resp
    , "model"   .= unModelId (_crsp_model resp)
    , "usage"   .= _crsp_usage resp
    ]

instance FromJSON CompletionResponse where
  parseJSON = Aeson.withObject "CompletionResponse" $ \o ->
    CompletionResponse
      <$> o .: "content"
      <*> (ModelId <$> o .: "model")
      <*> o .:? "usage"

instance ToJSON StreamEvent where
  toJSON (StreamText t)          = Aeson.object
    [ "type" .= ("text" :: Text), "text" .= t ]
  toJSON (StreamToolUse cid name) = Aeson.object
    [ "type" .= ("tool_use" :: Text), "id" .= unToolCallId cid, "name" .= name ]
  toJSON (StreamToolInput t)     = Aeson.object
    [ "type" .= ("tool_input" :: Text), "input" .= t ]
  toJSON (StreamWarning t)       = Aeson.object
    [ "type" .= ("warning" :: Text), "message" .= t ]
  toJSON (StreamDone resp)       = Aeson.object
    [ "type" .= ("done" :: Text), "response" .= resp ]

instance FromJSON StreamEvent where
  parseJSON = Aeson.withObject "StreamEvent" $ \o -> do
    tag <- o .: "type" :: Aeson.Parser Text
    case tag of
      "text"       -> StreamText <$> o .: "text"
      "tool_use"   -> (StreamToolUse . ToolCallId <$> (o .: "id")) <*> o .: "name"
      "tool_input" -> StreamToolInput <$> o .: "input"
      "warning"    -> StreamWarning <$> o .: "message"
      "done"       -> StreamDone <$> o .: "response"
      _            -> fail ("unknown StreamEvent type: " <> T.unpack tag)

-- | LLM provider interface. Each provider (Anthropic, OpenAI, etc.)
-- implements this typeclass.
class Provider p where
  complete :: p -> CompletionRequest -> IO CompletionResponse
  -- | Stream a completion, calling the callback for each event.
  -- Default falls back to non-streaming 'complete'.
  completeStream :: p -> CompletionRequest -> (StreamEvent -> IO ()) -> IO ()
  completeStream p req callback = do
    resp <- complete p req
    callback (StreamDone resp)
  -- | List available models from the provider.
  -- Default returns @[]@ (no model listing support).
  listModels :: p -> IO [ModelId]
  listModels _ = pure []

-- | Existential wrapper for runtime provider selection (e.g. from config).
data SomeProvider where
  MkProvider :: Provider p => p -> SomeProvider

instance Provider SomeProvider where
  complete (MkProvider p) = complete p
  completeStream (MkProvider p) = completeStream p
  listModels (MkProvider p) = listModels p
