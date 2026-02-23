module PureClaw.Providers.Class
  ( -- * Message types
    Role (..)
  , Message (..)
  , roleToText
    -- * Request and response
  , CompletionRequest (..)
  , CompletionResponse (..)
  , Usage (..)
    -- * Provider typeclass
  , Provider (..)
  ) where

import Data.Text (Text)

import PureClaw.Core.Types

-- | Role in a conversation. System prompts are handled separately
-- via 'CompletionRequest._cr_systemPrompt' rather than as messages,
-- since providers differ on how they handle system content.
data Role = User | Assistant
  deriving stock (Show, Eq, Ord)

-- | A single message in a conversation.
data Message = Message
  { _msg_role    :: Role
  , _msg_content :: Text
  }
  deriving stock (Show, Eq)

-- | Convert a role to its API text representation.
roleToText :: Role -> Text
roleToText User      = "user"
roleToText Assistant  = "assistant"

-- | Request to an LLM provider.
data CompletionRequest = CompletionRequest
  { _cr_model        :: ModelId
  , _cr_messages     :: [Message]
  , _cr_systemPrompt :: Maybe Text
  , _cr_maxTokens    :: Maybe Int
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
  { _crsp_content :: Text
  , _crsp_model   :: ModelId
  , _crsp_usage   :: Maybe Usage
  }
  deriving stock (Show, Eq)

-- | LLM provider interface. Each provider (Anthropic, OpenAI, etc.)
-- implements this typeclass. See 'PureClaw.Providers.Anthropic' for
-- the first real implementation.
class Provider p where
  complete :: p -> CompletionRequest -> IO CompletionResponse
