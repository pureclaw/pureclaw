module PureClaw.Handles.Harness
  ( -- * Types
    HarnessStatus (..)
  , HarnessHandle (..)
  , HarnessError (..)
    -- * Implementations
  , mkNoOpHarnessHandle
    -- * Output formatting
  , prefixHarnessOutput
  , sanitizeHarnessOutput
  ) where

import Data.ByteString (ByteString)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit

import PureClaw.Security.Command

-- | Status of a harness process.
data HarnessStatus
  = HarnessRunning
  | HarnessExited ExitCode
  deriving stock (Show, Eq)

-- | Errors that can occur during harness operations.
data HarnessError
  = HarnessNotAuthorized CommandError
  | HarnessBinaryNotFound Text
  | HarnessTmuxNotAvailable Text  -- ^ detail message (stderr from tmux, or "not found")
  deriving stock (Show, Eq)

-- | Capability handle for interacting with a harness (e.g. Claude Code in tmux).
data HarnessHandle = HarnessHandle
  { _hh_send    :: ByteString -> IO ()   -- ^ Write to harness input
  , _hh_receive :: IO ByteString         -- ^ Read harness output (scrollback capture)
  , _hh_name    :: Text                  -- ^ Human-readable name
  , _hh_session :: Text                  -- ^ tmux session name
  , _hh_status  :: IO HarnessStatus      -- ^ Check if running
  , _hh_stop    :: IO ()                 -- ^ Kill and cleanup
  }

-- | No-op harness handle for testing.
mkNoOpHarnessHandle :: HarnessHandle
mkNoOpHarnessHandle = HarnessHandle
  { _hh_send    = \_ -> pure ()
  , _hh_receive = pure ""
  , _hh_name    = ""
  , _hh_session = ""
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = pure ()
  }

-- | Prefix harness output with the origin name on the first line only.
-- e.g. @"claude-code-0\> line1\\nline2\\nline3"@.
-- This is the single abstraction for displaying messages from a harness\/model.
prefixHarnessOutput :: Text -> Text -> Text
prefixHarnessOutput name output = name <> "> " <> output

-- | Sanitize harness output for display in a TUI.
-- Strips ANSI escape sequences (CSI, OSC, DCS, etc.), C0\/C1 control
-- characters, and decorative Unicode (box drawing, block elements,
-- Private Use Area, etc.) that TUI applications use for rendering.
-- Also trims leading and trailing blank lines from tmux capture output.
sanitizeHarnessOutput :: Text -> Text
sanitizeHarnessOutput =
    trimBlankLines . T.pack . go . T.unpack
  where
    trimBlankLines =
      T.intercalate "\n"
      . dropWhileEnd isBlankLine
      . dropWhile isBlankLine
      . T.splitOn "\n"

    isBlankLine = T.all Char.isSpace

    dropWhileEnd _ [] = []
    dropWhileEnd p xs = reverse (dropWhile p (reverse xs))

    go [] = []
    go ('\ESC' : rest) = skipEscape rest
    -- Keep newlines and tabs
    go ('\n' : cs) = '\n' : go cs
    go ('\t' : cs) = '\t' : go cs
    -- Replace carriage return with newline (handles \r\n and bare \r)
    go ('\r' : '\n' : cs) = '\n' : go cs
    go ('\r' : cs) = '\n' : go cs
    -- Drop control characters, then decorative Unicode
    go (c : cs)
      | Char.isControl c  = go cs
      | isDecorativeChar c = go cs
      | otherwise          = c : go cs

    -- Skip ESC [ ... (final byte) — CSI sequences
    skipEscape ('[' : cs) = skipCsi cs
    -- Skip ESC ] ... ST — OSC sequences (terminated by BEL or ESC \)
    skipEscape (']' : cs) = skipOsc cs
    -- Skip ESC P ... ST — DCS sequences
    skipEscape ('P' : cs) = skipOsc cs
    -- Skip ESC ( X, ESC ) X — charset designators
    skipEscape ('(' : _ : cs) = go cs
    skipEscape (')' : _ : cs) = go cs
    -- Skip ESC followed by any single character (SS2, SS3, etc.)
    skipEscape (_ : cs) = go cs
    skipEscape [] = []

    -- CSI: skip parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F)
    -- until a final byte (0x40-0x7E)
    skipCsi [] = []
    skipCsi (c : cs)
      | c >= '@' && c <= '~' = go cs  -- final byte, done
      | otherwise             = skipCsi cs

    -- OSC / DCS: skip until BEL (0x07) or ST (ESC \)
    skipOsc [] = []
    skipOsc ('\BEL' : cs) = go cs
    skipOsc ('\ESC' : '\\' : cs) = go cs
    skipOsc (_ : cs) = skipOsc cs

-- | Characters used by TUI applications for rendering decorative elements.
-- These are valid Unicode but produce visual garbage when displayed outside
-- the originating terminal application.
isDecorativeChar :: Char -> Bool
isDecorativeChar c = let cp = Char.ord c in
  -- Box Drawing (U+2500–U+257F)
     (cp >= 0x2500 && cp <= 0x257F)
  -- Block Elements (U+2580–U+259F)
  || (cp >= 0x2580 && cp <= 0x259F)
  -- Geometric Shapes (U+25A0–U+25FF) — squares, circles, triangles
  || (cp >= 0x25A0 && cp <= 0x25FF)
  -- Braille Patterns (U+2800–U+28FF) — used for sparklines/graphs
  || (cp >= 0x2800 && cp <= 0x28FF)
  -- Private Use Area (U+E000–U+F8FF) — Powerline, Nerd Font icons
  || (cp >= 0xE000 && cp <= 0xF8FF)
  -- Supplementary Private Use Areas (U+F0000–U+10FFFF)
  || cp >= 0xF0000
