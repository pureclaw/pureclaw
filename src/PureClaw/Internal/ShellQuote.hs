-- |
-- Module      : PureClaw.Internal.ShellQuote
-- Description : Canonical single-quote shell quoter (WU4).
--
-- Single source of truth for POSIX single-quote-style shell quoting
-- across PureClaw. The output is safe to splice into a command line
-- that will be re-parsed by a POSIX-compatible shell ('sh', 'bash',
-- 'dash', the remote login shell sshd hands off to, etc.).
--
-- Quoting rules:
--
--   * The empty string returns the literal two-character output @''@
--     (so an empty positional arg survives shell re-tokenisation).
--
--   * Inputs whose characters are all in the \"safe\" set
--     @[A-Za-z0-9_./=:@-]@ are returned unchanged — quoting them
--     would only add noise to logs and command-line traces.
--
--   * All other inputs are wrapped in single quotes. Embedded single
--     quotes are emitted as the four-character sequence @'\\''@
--     (close-quote, backslash-escaped quote, reopen-quote), which is
--     the canonical idiom for embedding a literal single quote inside
--     a single-quoted POSIX string.
--
-- The byte-for-byte semantics match the original
-- 'PureClaw.Harness.Tmux.shellEscape' / 'shellEscapeStr' helpers, which
-- have been in production use; this module is now the canonical
-- location for new code, and the 'Harness.Tmux' names delegate here.
--
-- See @docs\/terminal-backend-abstractions.md@ § \"Remote arg quoting\"
-- and § \"Scope of Harness.Tmux migration\".
module PureClaw.Internal.ShellQuote
  ( shellQuote
  , shellQuoteString
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Quote a 'Text' for inclusion as a single argument in a POSIX
-- shell command line.
--
-- See the module haddock for the full rules. Examples:
--
-- >>> shellQuote ""
-- "''"
--
-- >>> shellQuote "hello"
-- "hello"
--
-- >>> shellQuote "hello world"
-- "'hello world'"
--
-- >>> shellQuote "it's"
-- "'it'\\''s'"
shellQuote :: Text -> Text
shellQuote t
  | T.null t = "''"
  | T.all isSafe t = t
  | otherwise = "'" <> T.replace "'" "'\\''" t <> "'"
  where
    isSafe c = c `elem` safeChars
    safeChars = ['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "-_./=:@"

-- | 'String'-typed convenience wrapper around 'shellQuote' for callers
-- working with 'FilePath' or other @String@-shaped argv values.
shellQuoteString :: String -> String
shellQuoteString = T.unpack . shellQuote . T.pack
