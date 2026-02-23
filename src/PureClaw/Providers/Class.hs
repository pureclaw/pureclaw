module PureClaw.Providers.Class
  ( -- * Message types
    Role (..)
  , ContentBlock (..)
  , Message (..)
  , roleToText
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
    -- * Provider typeclass
  , Provider (..)
    -- * Existential wrapper
  , SomeProvider (..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Text qualified as T

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
  | ToolUseBlock
      { _tub_id    :: ToolCallId
      , _tub_name  :: Text
      , _tub_input :: Value
      }
  | ToolResultBlock
      { _trb_toolUseId :: ToolCallId
      , _trb_content   :: Text
      , _trb_isError   :: Bool
      }
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
toolResultMessage :: [(ToolCallId, Text, Bool)] -> Message
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

-- | LLM provider interface. Each provider (Anthropic, OpenAI, etc.)
-- implements this typeclass.
class Provider p where
  complete :: p -> CompletionRequest -> IO CompletionResponse

-- | Existential wrapper for runtime provider selection (e.g. from config).
data SomeProvider where
  MkProvider :: Provider p => p -> SomeProvider

instance Provider SomeProvider where
  complete (MkProvider p) = complete p
