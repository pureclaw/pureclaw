module PureClaw.Agent.Context
  ( -- * Context type (constructor intentionally NOT exported)
    Context
    -- * Construction
  , emptyContext
    -- * Operations
  , addMessage
  , contextMessages
  , contextSystemPrompt
  ) where

import Data.Text (Text)

import PureClaw.Providers.Class

-- | Conversation context. Maintains message history and an optional
-- system prompt. Constructor is not exported — use 'emptyContext'.
data Context = Context
  { _ctx_systemPrompt :: Maybe Text
  , _ctx_messages     :: [Message]  -- oldest first
  }
  deriving stock (Show, Eq)

-- | Create an empty context with an optional system prompt.
emptyContext :: Maybe Text -> Context
emptyContext sys = Context sys []

-- | Append a message to the conversation history.
addMessage :: Message -> Context -> Context
addMessage msg ctx = ctx { _ctx_messages = _ctx_messages ctx ++ [msg] }

-- | Get all messages in chronological order.
contextMessages :: Context -> [Message]
contextMessages = _ctx_messages

-- | Get the system prompt, if any.
contextSystemPrompt :: Context -> Maybe Text
contextSystemPrompt = _ctx_systemPrompt
