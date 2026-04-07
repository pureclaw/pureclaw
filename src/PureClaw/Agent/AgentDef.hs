module PureClaw.Agent.AgentDef
  ( -- * Agent name (smart constructor)
    AgentName
  , unAgentName
  , mkAgentName
  , AgentNameError (..)
  ) where

import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T

-- | Validated agent name. The data constructor is intentionally NOT exported —
-- the only way to obtain an 'AgentName' is through 'mkAgentName'.
newtype AgentName = AgentName { unAgentName :: Text }
  deriving stock (Eq, Ord, Show)

-- | Reasons a raw 'Text' cannot be promoted to an 'AgentName'.
data AgentNameError
  = AgentNameEmpty
  | AgentNameTooLong
  | AgentNameInvalidChars Text
  | AgentNameLeadingDot
  deriving stock (Eq, Show)

-- | Maximum allowed length for an agent name.
agentNameMaxLength :: Int
agentNameMaxLength = 64

-- | Valid character predicate: ASCII letters, digits, underscore, hyphen.
isValidAgentNameChar :: Char -> Bool
isValidAgentNameChar c =
  Char.isAsciiUpper c
    || Char.isAsciiLower c
    || Char.isDigit c
    || c == '_'
    || c == '-'

-- | Smart constructor. Rejects empty names, names longer than 64 characters,
-- names with a leading dot (hidden), and names containing any character
-- outside @[a-zA-Z0-9_-]@ (which in particular rejects @.@, @/@, and null).
mkAgentName :: Text -> Either AgentNameError AgentName
mkAgentName raw
  | T.null raw = Left AgentNameEmpty
  | T.length raw > agentNameMaxLength = Left AgentNameTooLong
  | T.head raw == '.' && T.all isValidAgentNameChar (T.tail raw) = Left AgentNameLeadingDot
  | not (T.all isValidAgentNameChar raw) = Left (AgentNameInvalidChars raw)
  | otherwise = Right (AgentName raw)
