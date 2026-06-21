{-# LANGUAGE OverloadedStrings #-}

-- | Per-flavour, PURE detection and extraction of harness terminal output.
-- Each harness TUI (Claude Code, Codex, …) draws its screen differently, so
-- working/idle/awaiting-input detection and response extraction are
-- flavour-specific. The reconcile loop and the @/harness output@ command both
-- select an observer via 'observerFor'. Heuristics are facts about each tool's
-- terminal output; they were validated against live captures.
module PureClaw.Harness.Observer
  ( HarnessActivityState (..)
  , HarnessObserver (..)
  , observerFor
  , claudeObserver
  , genericObserver
  ) where

import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Char (isSpace)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           PureClaw.Session.Kind (HarnessFlavour (..))

data HarnessActivityState = HasWorking | HasAwaitingInput | HasIdle
  deriving stock (Eq, Show)

data HarnessObserver = HarnessObserver
  { _ho_classify        :: Text -> HarnessActivityState
  , _ho_extractResponse :: Int -> ByteString -> Text
  , _ho_relevantTail    :: Int -> ByteString -> Text
  }

observerFor :: HarnessFlavour -> HarnessObserver
observerFor HClaudeCode = claudeObserver
observerFor _           = genericObserver

-- ── Claude Code ────────────────────────────────────────────────────────────

-- | Spinner glyphs Claude rotates while working (Dingbats range + a few extras).
-- NOTE: the response-marker characters ⏺ (U+23FA), ● (U+25CF), and ⬤ (U+2B24)
-- are intentionally NOT included here — they introduce those glyph characters as
-- actual content (e.g. "⏺ Let me check the other call sites…") and must NOT be
-- classified as working-spinner lines.  'isResponseMarkerLine' handles them for
-- extraction; classification sees them only via the idle-prompt path.
claudeSpinnerGlyphs :: [Char]
claudeSpinnerGlyphs =
  "\x2022"   -- •  BULLET
  <> "\x2019"   -- '  RIGHT SINGLE QUOTATION MARK (used in some spinner patterns)
  <> "\x2726"   -- ✦  BLACK FOUR POINTED STAR
  <> "\x2732"   -- ✲  OPEN CENTRE ASTERISK
  <> "\x2733"   -- ✳  EIGHT SPOKED ASTERISK
  <> "\x2734"   -- ✴  EIGHT POINTED BLACK STAR
  <> "\x2735"   -- ✵  EIGHT POINTED PINWHEEL STAR
  <> "\x2736"   -- ✶  SIX POINTED BLACK STAR
  <> "\x2737"   -- ✷  EIGHT POINTED RECTILINEAR BLACK STAR
  <> "\x2738"   -- ✸  HEAVY EIGHT POINTED RECTILINEAR BLACK STAR
  <> "\x2739"   -- ✹  TWELVE POINTED BLACK STAR
  <> "\x273A"   -- ✺  SIXTEEN POINTED ASTERISK
  <> "\x273B"   -- ✻  TEARDROP-SPOKED ASTERISK
  <> "\x273C"   -- ✼  OPEN CENTRE TEARDROP-SPOKED ASTERISK
  <> "\x273D"   -- ✽  HEAVY TEARDROP-SPOKED ASTERISK
  <> "\x273E"   -- ✾  SIX PETALLED BLACK AND WHITE FLORETTE
  <> "\x273F"   -- ✿  BLACK FLORETTE
  <> "\x2605"   -- ★  BLACK STAR
  <> "\x22C6"   -- ⋆  STAR OPERATOR
  <> "\x22C7"   -- ⋇  DIVISION TIMES
  <> "\x2642"   -- ♂  MALE SIGN (used in some Hermes spinner patterns)
  <> "\x2666"   -- ♦  BLACK DIAMOND SUIT
  <> "\x00B7"   -- ·  MIDDLE DOT
  <> "\x2026"   -- …  HORIZONTAL ELLIPSIS (shouldn't start a line, belt-and-suspenders)

-- Additional spinner chars observed in the wild (Hermes, faryo patterns).
-- Claude Code uses the ✶ (U+2736) glyph as the primary working-status marker.
-- The status line for "working" looks like: ✶ Smooshing… (4m 55s · ↓ 16.6k tokens)

-- | A working/status line: starts with a spinner/star glyph followed by
-- a description containing ellipsis or a token counter in parens, or the
-- @esc to interrupt@ hint.
isClaudeWorkingLine :: Text -> Bool
isClaudeWorkingLine raw =
  let l = T.stripStart raw
  in (not (T.null l) && isSpinnerGlyph (T.head l)
       && (T.isInfixOf "\x2026" l || T.isInfixOf "..." l))   -- … or ...
     || hasTokenCounter l
     || T.isInfixOf "esc to interrupt" (T.toLower l)
  where
    -- A spinner glyph is any character in 'claudeSpinnerGlyphs'.
    isSpinnerGlyph c = c `elem` claudeSpinnerGlyphs
    hasTokenCounter t =
      T.isInfixOf "tokens" (T.toLower t)
      && T.isInfixOf "(" t && T.isInfixOf ")" t

-- | An approval/menu prompt: Claude is blocked on the user.
isClaudeApprovalLine :: Text -> Bool
isClaudeApprovalLine raw =
  let l = T.toLower (T.stripStart raw)
  in T.isInfixOf "do you want to proceed?" l
     || T.isInfixOf "yes, and don't ask again" l
     || T.isInfixOf "yes, and don\x2019t ask again" l
     || T.isInfixOf "enter to confirm" l
     || T.isInfixOf "esc to cancel" l
     || isNumberedYesNo (T.stripStart raw)

-- | A numbered option line, optionally led by the @❯@ menu cursor: @❯ 1. Yes@.
-- Matches lines like "❯ 1. Yes", "  2. No", "1. Something".
isNumberedYesNo :: Text -> Bool
isNumberedYesNo l0 =
  -- strip leading ❯ ›  and spaces
  let l = T.dropWhile (\c -> c == '\x276F' || c == '\x203A' || c == ' ') l0
  in case T.span (\c -> c >= '0' && c <= '9') l of
       (ds, rest) -> not (T.null ds) && T.isPrefixOf "." rest

-- | The idle input prompt: a bare @❯@/@›@ NOT followed by a number+dot
-- (which would be a menu-selection cursor, not the prompt).
isIdlePromptLine :: Text -> Bool
isIdlePromptLine raw =
  let l = T.stripStart raw
  in (T.isPrefixOf "\x276F" l || T.isPrefixOf "\x203A" l)  -- ❯ ›
     && not (isNumberedYesNo l)
     && T.null (T.strip (T.drop 1 l))  -- nothing after the prompt glyph

classifyClaude :: Text -> HarnessActivityState
classifyClaude screen =
  let ls = T.lines screen
  in if any isClaudeWorkingLine ls then HasWorking
     else if any isClaudeApprovalLine ls then HasAwaitingInput
     else HasIdle

-- | True for chrome lines that must never appear in extracted output.
isClaudeChrome :: Text -> Bool
isClaudeChrome raw =
  let l = T.stripStart raw
  in T.null (T.strip l)
     || isClaudeWorkingLine raw
     || (isIdlePromptLine raw)
     || T.isInfixOf "for shortcuts" (T.toLower l)
     || T.isInfixOf "ctrl+o to expand" (T.toLower l)
     || isBoxDrawingLine l  -- ─ ▀ ▄ lines (horizontal rules)

isBoxDrawingLine :: Text -> Bool
isBoxDrawingLine l =
  not (T.null l)
  && T.all (\c -> c == '\x2500' || c == '\x2580' || c == '\x2584' || isSpace c) l

isResponseMarkerLine :: Text -> Bool
isResponseMarkerLine line =
  let l = T.stripStart line
  in T.isPrefixOf "\x23FA" l    -- ⏺
     || T.isPrefixOf "\x25CF" l -- ● (alternate, faryo)
     || T.isPrefixOf "\x2B24" l -- ⬤ (alternate)

stripResponseMarker :: Text -> Text
stripResponseMarker line =
  T.stripStart (T.dropWhile (`elem` ("\x23FA\x25CF\x2B24 " :: String)) (T.stripStart line))

-- | Extract the latest assistant response. @baseline@ is the number of lines
-- already seen (used to skip already-delivered content). When awaiting input,
-- return the approval/menu prompt block so the user sees the question.
extractClaude :: Int -> ByteString -> Text
extractClaude baseline capture =
  let body = dropBaseline baseline capture
      ls   = T.lines (TE.decodeUtf8Lenient body)
  in if any isClaudeApprovalLine ls
       then T.strip . T.unlines $ dropWhile (not . isClaudeApprovalLine) ls
       else case reverse [ i | (i, l) <- zip [0 :: Int ..] ls, isResponseMarkerLine l ] of
              []      -> ""
              (i : _) ->
                let block   = takeWhile (not . isIdlePromptLine) (drop i ls)
                    cleaned = case block of
                      (h : rest) -> stripResponseMarker h : filter (not . isClaudeChrome) rest
                      []         -> []
                in T.strip (T.intercalate "\n" (filter (not . T.null) cleaned))

relevantTailClaude :: Int -> ByteString -> Text
relevantTailClaude n capture =
  let ls = filter (not . isClaudeChrome) (T.lines (TE.decodeUtf8Lenient capture))
  in T.intercalate "\n" (lastN n ls)

claudeObserver :: HarnessObserver
claudeObserver = HarnessObserver
  { _ho_classify        = classifyClaude
  , _ho_extractResponse = extractClaude
  , _ho_relevantTail    = relevantTailClaude
  }

-- ── Generic fallback (Codex/OpenCode/Hermes/PureClaw/Custom) ─────────────────

-- | Generic observer for non-Claude harnesses. Classification is always
-- 'HasIdle' — stability over time (in the reconcile loop) is the only signal.
genericObserver :: HarnessObserver
genericObserver = HarnessObserver
  { _ho_classify        = const HasIdle
  , _ho_extractResponse = \n cap ->
      let ls = cleanLines cap
      in if n <= 0
           then T.intercalate "\n" ls
           else T.intercalate "\n" (lastN n ls)
  , _ho_relevantTail    = \n cap -> T.intercalate "\n" (lastN n (cleanLines cap))
  }
  where
    cleanLines cap = filter (not . T.null . T.strip) (T.lines (TE.decodeUtf8Lenient cap))

-- ── Shared helpers ───────────────────────────────────────────────────────────

dropBaseline :: Int -> ByteString -> ByteString
dropBaseline n cap
  | n <= 0    = cap
  | otherwise = BS.intercalate (BS.singleton 0x0A) (drop n (BS.split 0x0A cap))

lastN :: Int -> [a] -> [a]
lastN n xs = drop (max 0 (length xs - n)) xs
