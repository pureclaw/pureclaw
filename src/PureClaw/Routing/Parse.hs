-- |
-- Module      : PureClaw.Routing.Parse
-- Description : Slash-input parser + shared sanitizers (Tabbed Chat WU2).
--
-- This module owns the slash-input grammar for Tabbed Chat (#51):
--
--   * @parseInput :: RoutingConfig -> Text -> Either ParseError ParsedInput@
--     classifies a single user message into 'Switch' \/ 'Inject' \/
--     'Default' \/ 'ParsedSlashCmd' per the grammar at
--     @docs\/tabbed-chat.md@ §"Routing Grammar (v1)".
--   * @parseSlashCommand :: Text -> Maybe SlashCommand@ is the
--     re-exported in-tab-loop entry-point used by AI tab loops (WU6, I2
--     contract) when an inbound 'UserText' starts with @\/@.
--   * @mkSessionId :: Text -> Either ParseError SessionId@ enforces the
--     S3 \/ P15a corpus: rejects @\/@, @\\@, @..@, @NUL@, and any
--     character outside @[a-zA-Z0-9_-]@.
--   * @sanitizeTabName :: Text -> Either NameError Text@ is the shared
--     sanitization function used by every code path that sets
--     @_tabHandle_name@ (H11) AND the @\/tab rename@ handler (S10).
--
-- == Grammar (single-char index, [0-9a-z])
--
-- @
-- input        ::= switch | inject | default | slash-cmd
-- switch       ::= \'\/\' IDX
-- inject       ::= \'\/\' IDX WS payload
-- default      ::= payload
-- slash-cmd    ::= \'\/\' WORD ...
--              |   \'\/tab\' WS action [WS args]
--              |   \'\/tabs\'
-- IDX          ::= [0-9a-z]        -- exactly one character
-- WS           ::= one or more spaces\/tabs
-- @
--
-- The index is exactly one character; digits @0-9@ map to tab indices
-- @0..9@ and lowercase letters @a-z@ map to tab indices @10..35@. This
-- gives a 36-tab maximum (matching @_rc_maxTabs@ default). Multi-char
-- indices like @\/10@, @\/12@, @\/aa@, or @\/1a@ are rejected as
-- 'ParseErrorMalformed' — there is no greedy digit run any more.
--
-- @\/0 0 run@ parses as @Inject 0 \"0 run\"@ — the payload character
-- after the WS separator is preserved verbatim per P4.
--
-- The @\/0@ vs @\/0 \<text\>@ disambiguation is whitespace-driven:
-- @\/0@ alone (or with trailing whitespace only) is a 'Switch';
-- @\/0 \<anything-non-blank\>@ is an 'Inject'. The @\<text\>@ side of
-- 'Inject' preserves all characters after the first whitespace
-- separator, including embedded newlines (the channel layer is
-- responsible for splitting incoming messages at newlines if it wants
-- per-line semantics; we treat the message as a single input).
--
-- == Notes
--
--   * Index bounds-checking uses 'RoutingConfig._rc_maxTabs'. WU1's
--     'mkTabIndex' enforces the floor only; the parser enforces the
--     ceiling and emits 'ParseErrorIndexOutOfRange' on failure.
--   * @\/0@ with a non-whitespace tail (e.g. @\/01@) is rejected as
--     'ParseErrorMalformed' — the single-char grammar admits no
--     multi-char numeric or alphanumeric indices.
--   * @\/tab resume \<id\>@ runs the id through 'mkSessionId' at parse
--     time per P15a (so the dispatcher never sees an unvalidated id);
--     rejection surfaces as 'ParseErrorInvalidSessionId'.
module PureClaw.Routing.Parse
  ( -- * Slash-input parser
    parseInput
  , parseSlashCommand
    -- * Smart constructors
  , mkSessionId
  , sanitizeTabName
  , sanitizeTabNameWith
    -- * Defaults used by the bare 'sanitizeTabName'
  , defaultMaxNameLen
  ) where

import Data.Char qualified as Char
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types qualified as Core
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Internal.Redact qualified as Redact
import PureClaw.Routing.Types qualified as RT


-- ---------------------------------------------------------------------------
-- parseInput
-- ---------------------------------------------------------------------------

-- | Parse a single incoming message into the high-level routing
-- classification.
--
-- See module haddock for the grammar; see @docs\/tabbed-chat.md@
-- §"Parser invariants" for the per-form contract.
parseInput :: RT.RoutingConfig -> Text -> Either RT.ParseError RT.ParsedInput
parseInput rc raw
  | T.null trimmedLeft = Left RT.ParseErrorEmptyInput
  | not slashy        = Right (RT.Default raw)
  | otherwise         = classifySlashy rc trimmedLeft raw
  where
    -- We only drop leading whitespace; trailing whitespace is part of
    -- the payload semantics ('/0 ' alone collapses to a Switch per the
    -- "trailing-whitespace-only payload" rule).
    trimmedLeft = T.dropWhile isHSpace raw
    slashy      = case T.uncons trimmedLeft of
      Just ('/', _) -> True
      _             -> False

-- | Dispatch on the shape after the leading @\/@.
--
--   * If the body is a single index char @c \in [0-9a-z]@ followed
--     by end-of-input or whitespace, we have a 'Switch' (no payload)
--     or 'Inject' (with payload).
--   * Anything longer that starts with a digit (e.g. @\/12@,
--     @\/1a@) is malformed — there is no greedy index any more.
--     Bonus: @\/01@ \/ @\/02@ also fall here.
--   * Anything longer that starts with a letter (e.g. @\/help@,
--     @\/session new@) is routed through the slash-command parser.
--
-- The whitespace-or-EOI lookahead on the second character is what
-- disambiguates @\/s@ (Switch to tab 28) from @\/session new@
-- (slash command). The lookahead is a single 'T.uncons' on the
-- tail; no second pass over the input.
classifySlashy
  :: RT.RoutingConfig
  -> Text   -- ^ leading-whitespace-stripped input (starts with @\/@)
  -> Text   -- ^ original input (preserved for the slash-cmd fallback)
  -> Either RT.ParseError RT.ParsedInput
classifySlashy rc t orig =
  let body = T.drop 1 t   -- drop the leading '/'
  in case T.uncons body of
       Nothing -> Left RT.ParseErrorMalformed
       Just (c, rest)
         | Just n  <- parseTabIndexChar c
         , isIndexBoundary rest         -> parseIndexCharForm rc n rest
         | Char.isDigit c               ->
             -- Digit followed by more (non-WS) characters: legacy
             -- multi-digit shapes (@\/12@, @\/01@, @\/1a@) are no
             -- longer in the grammar. They cannot be slash commands
             -- either (commands start with a letter), so reject.
             Left RT.ParseErrorMalformed
         | otherwise                    -> parseSlashCommandForm orig

-- | True when the byte following the single index char is end-of-input
-- or whitespace (space, tab, newline, carriage return). Anything else
-- means the index char was the first letter of a word — punt to the
-- slash-command parser.
isIndexBoundary :: Text -> Bool
isIndexBoundary rest = case T.uncons rest of
  Nothing     -> True
  Just (c, _) -> isHSpace c || c == '\n' || c == '\r'

-- | Map a single ASCII character to its tab index.
--
--   * @\'0\'-\'9\'@ → @0..9@
--   * @\'a\'-\'z\'@ → @10..35@
--   * anything else → 'Nothing'
--
-- This is the only place the single-char index alphabet is encoded;
-- the parser, dashboard, and any future readers should reuse this
-- function rather than re-implementing the mapping.
parseTabIndexChar :: Char -> Maybe Int
parseTabIndexChar c
  | Char.isDigit c        = Just (Char.ord c - Char.ord '0')
  | Char.isAsciiLower c   = Just (10 + Char.ord c - Char.ord 'a')
  | otherwise             = Nothing

-- | Parse the @\/IDX [WS payload]@ form. The caller has already
-- (a) decoded the index char to an 'Int' and (b) confirmed via
-- 'isIndexBoundary' that @rest@ is empty or starts with whitespace.
-- We bounds-check the index against @_rc_maxTabs@ and hand off to
-- 'classifyAfterIndex' to decide Switch vs Inject.
parseIndexCharForm
  :: RT.RoutingConfig
  -> Int    -- ^ decoded index from the single index character
  -> Text   -- ^ everything after the index character (WS or empty by caller invariant)
  -> Either RT.ParseError RT.ParsedInput
parseIndexCharForm rc n rest = do
  ti <- boundedTabIndex rc n
  classifyAfterIndex ti rest

-- | Bounds-check an 'Int' against @_rc_maxTabs@ and build a
-- 'Tab.TabIndex' on success.
--
-- WU1's 'Tab.mkTabIndex' enforces only the floor (@n >= 0@); we
-- enforce the ceiling here. Caller invariant: @n >= 0@ — the single
-- index character produced by 'parseTabIndexChar' is always in
-- @[0..35]@, so 'Tab.mkTabIndex' always returns 'Just'. We collapse
-- the structurally-unreachable 'Nothing' branch into a single 'error'
-- call via 'Maybe.fromMaybe' so the HPC report has no defensive dead
-- arm to flag.
boundedTabIndex
  :: RT.RoutingConfig
  -> Int
  -> Either RT.ParseError Tab.TabIndex
boundedTabIndex rc n
  | n >= RT._rc_maxTabs rc = Left (RT.ParseErrorIndexOutOfRange n)
  | otherwise =
      Right (Maybe.fromMaybe
               (error "PureClaw.Routing.Parse.boundedTabIndex: \
                      \mkTabIndex returned Nothing for n >= 0 — \
                      \caller invariant violated")
               (Tab.mkTabIndex n))

-- | After consuming the digit run, decide between 'Switch' (no payload)
-- and 'Inject' (payload preserved verbatim after the separator).
--
-- Newline handling per the design's multi-line rule: a newline
-- immediately after the digit run counts as a separator, but the
-- payload includes the newline (so @\/0\\nfoo@ → @Inject 0 \"\\nfoo\"@).
-- Horizontal whitespace (space \/ tab) is consumed and the payload
-- starts at the first non-blank byte (so @\/0 run tests@ →
-- @Inject 0 \"run tests\"@).
--
-- 'shapeCheckRest' has already rejected the malformed @\/12abc@ case
-- before this function is called, so the first char of @rest@ here is
-- guaranteed to be a horizontal-WS, newline, or carriage return when
-- @rest@ is non-empty.
classifyAfterIndex :: Tab.TabIndex -> Text -> Either RT.ParseError RT.ParsedInput
classifyAfterIndex ti rest
  | T.null rest = Right (RT.Switch ti)
  | otherwise   =
      let (_hSep, afterHSep)  = T.span isHSpace rest
          startsWithNewline   = case T.uncons afterHSep of
                                  Just (c, _) -> c == '\n' || c == '\r'
                                  Nothing     -> False
      in if startsWithNewline
           then
             -- The newline (and everything after it, including any
             -- trailing hSpace) IS the payload: a multi-line input
             -- like @\/0\\nfoo@ produces @Inject 0 \"\\nfoo\"@; an
             -- input ending right at the newline like @\/0\\n@
             -- produces @Inject 0 \"\\n\"@.
             Right (RT.Inject ti afterHSep)
           else
             -- Horizontal-WS-only separator. Drop the leading hSpace
             -- from the payload; if nothing meaningful remains, treat
             -- the trailing whitespace as belonging to the bare switch
             -- ("/0 " rule).
             let payload = T.dropWhile isHSpace afterHSep
             in if T.null payload
                  then Right (RT.Switch ti)
                  else Right (RT.Inject ti payload)

-- | Whitespace-class used by the parser. Excludes newlines so that a
-- newline embedded in @\/0\\nfoo@ is treated as payload (per the
-- design's multi-line guidance), not as a separator that strips
-- preceding whitespace.
isHSpace :: Char -> Bool
isHSpace c = c == ' ' || c == '\t'


-- ---------------------------------------------------------------------------
-- parseSlashCommand bridge
-- ---------------------------------------------------------------------------

-- | The slash-cmd branch of 'parseInput' (e.g. @\/help@, @\/vault add foo@,
-- @\/tab new 3 shell@, @\/tabs@).
--
-- Re-uses the existing 'PureClaw.Agent.SlashCommands.parseSlashCommand'
-- so there is no parser divergence between Tabbed Chat's preprocessor
-- and the in-tab-loop I2 re-parse path (AI tab loop receives
-- @UserText t@ starting with @\/@ and calls 'parseSlashCommand'
-- directly).
--
-- Special-case for P15a: @\/tab resume \<bad-id\>@ is surfaced as the
-- dedicated 'RT.ParseErrorInvalidSessionId' (not the generic
-- 'RT.ParseErrorMalformed') so the user sees a useful rejection
-- reason. Other slash-cmd shapes fall through to the generic parser.
--
-- Otherwise: success becomes 'RT.ParsedSlashCmd'; failure becomes
-- 'RT.ParseErrorMalformed' (a @\/@-prefixed input that matches no
-- known command is an error, not a 'Default').
parseSlashCommandForm :: Text -> Either RT.ParseError RT.ParsedInput
parseSlashCommandForm orig
  -- Detect a /tab resume <id> shape with an invalid id so we can
  -- emit the specific ParseErrorInvalidSessionId code (P15a).
  | isTabResumeShape orig
  , Left e <- mkSessionId (extractTabResumeArg orig)
  = Left e
  | otherwise = case parseSlashCommand orig of
      Just cmd -> Right (RT.ParsedSlashCmd cmd)
      Nothing  -> Left RT.ParseErrorMalformed

-- | True if the input begins with @\/tab resume @ followed by at least
-- one non-blank character (case-insensitive on the keywords).
--
-- Intentionally permissive on what follows the prefix — including
-- inputs that contain spaces, control bytes, or path separators —
-- because the dedicated 'ParseErrorInvalidSessionId' code path needs
-- to fire for ANY ill-formed id, not just well-shaped-but-rejected
-- ones.
isTabResumeShape :: Text -> Bool
isTabResumeShape t =
  let stripped = T.strip t
      lower    = T.toLower stripped
      pfx      = "/tab resume "
  in pfx `T.isPrefixOf` lower
       && not (T.null (T.strip (T.drop (T.length pfx) stripped)))

-- | Extract the everything-after-@\/tab resume @ argument blob.
-- Caller ensures shape via 'isTabResumeShape'.
extractTabResumeArg :: Text -> Text
extractTabResumeArg t =
  let stripped = T.strip t
      pfx      = "/tab resume "
  in T.strip (T.drop (T.length pfx) stripped)

-- | The in-tab-loop I2 re-parser. Includes the Tabbed Chat
-- @\/tab*@ / @\/tabs@ family in addition to the existing slash
-- commands.
--
-- A plain @parseSlashCommand "/foo"@ returns 'Nothing' for unknown
-- commands; this wrapper preserves that contract while folding in the
-- new @\/tab@ command family before delegating to
-- 'Slash.parseSlashCommand'.
parseSlashCommand :: Text -> Maybe Slash.SlashCommand
parseSlashCommand input =
  let stripped = T.strip input
  in case parseTabFamily stripped of
       Just cmd -> Just cmd
       Nothing  -> Slash.parseSlashCommand stripped


-- ---------------------------------------------------------------------------
-- /tab* family parsers
-- ---------------------------------------------------------------------------

-- | Recognise the @\/tab@ / @\/tabs@ command family. Returns 'Nothing'
-- for inputs outside this family so the caller can fall back to the
-- existing slash-command parsers without parser divergence.
parseTabFamily :: Text -> Maybe Slash.SlashCommand
parseTabFamily t
  -- /tabs is the bare alias for /tab list.
  | lower == "/tabs" = Just (Slash.CmdTab Slash.TabListCmd)
  | lower == "/tab"  = Nothing   -- bare /tab is not a command (would need a sub)
  | "/tab " `T.isPrefixOf` lower =
      let rest = T.strip (T.drop (T.length "/tab ") t)
      in parseTabAction rest
  | otherwise = Nothing
  where
    lower = T.toLower t

-- | Dispatch on the @\<action\>@ word: @list@ \/ @new\<N\>@ \/
-- @close\<N\>@ \/ @focus\<N\>@ \/ @resume\<id\>@ \/ @rename\<N\>@.
--
-- The caller in 'parseTabFamily' has already stripped surrounding
-- whitespace and ensured the @\/tab @ prefix is followed by at least
-- one non-blank character; so @T.words rest@ here always produces a
-- non-empty list.
parseTabAction :: Text -> Maybe Slash.SlashCommand
parseTabAction rest = case T.words rest of
  []         -> Nothing  -- defensive; caller ensures non-empty
  (act:args) -> case T.toLower act of
    "list"   -> if null args then Just (Slash.CmdTab Slash.TabListCmd) else Nothing
    "new"    -> parseTabNew args
    "close"  -> parseTabClose args
    "focus"  -> parseTabFocus args
    "resume" -> parseTabResume args
    "rename" -> parseTabRename args rest
    _        -> Nothing

-- | @\/tab new [\<kind\> [\<arg-text\>]]@.
--
-- The grammar deliberately omits a user-specified index: new tabs are
-- always allocated at the lowest free slot by the handler (tmux-style
-- packing). @\/tab new@ with no kind force-prompts the user; with a
-- kind it spawns directly.
parseTabNew :: [Text] -> Maybe Slash.SlashCommand
parseTabNew []        = Just (Slash.CmdTab (Slash.TabNewCmd Nothing Nothing))
parseTabNew (k:argTs) = do
  kind <- parseTabKindArg k
  let argText = if null argTs
                  then Nothing
                  else Just (T.unwords argTs)
  Just (Slash.CmdTab (Slash.TabNewCmd (Just kind) argText))

-- | @\/tab close \<N\> [--force]@.
parseTabClose :: [Text] -> Maybe Slash.SlashCommand
parseTabClose []     = Nothing
parseTabClose (n:fs) = do
  idx <- parseDecimalIndex n
  force <- case fs of
             []           -> Just Slash.ForceNo
             ["--force"]  -> Just Slash.ForceYes
             _            -> Nothing
  Just (Slash.CmdTab (Slash.TabCloseCmd idx force))

-- | @\/tab focus \<N\>@.
parseTabFocus :: [Text] -> Maybe Slash.SlashCommand
parseTabFocus [n] = do
  idx <- parseDecimalIndex n
  Just (Slash.CmdTab (Slash.TabFocusCmd idx))
parseTabFocus _   = Nothing

-- | @\/tab resume \<session-id\>@. The id is run through 'mkSessionId'
-- so that S3 \/ P15a rejection (path traversal, NUL, non-alnum)
-- happens at parser time. We return 'Nothing' on rejection here and
-- rely on the @\/@-prefixed-must-parse policy in
-- 'parseSlashCommandForm' to surface this as 'ParseErrorMalformed'.
-- The dedicated 'ParseErrorInvalidSessionId' code is emitted by
-- 'parseInput' below when it recognises a @\/tab resume@ shape with
-- a bad id.
parseTabResume :: [Text] -> Maybe Slash.SlashCommand
parseTabResume [idText] = case mkSessionId idText of
  Right sid -> Just (Slash.CmdTab (Slash.TabResumeCmd sid))
  Left _    -> Nothing
parseTabResume _        = Nothing

-- | @\/tab rename \<N\> \<name\>@. The original rest-of-line is taken
-- so that names with embedded whitespace (e.g. @"my shell"@) survive
-- intact.
--
-- Caller invariant: when @args@ has >= 2 elements, the rest-of-line
-- 'line' contains at least @"rename N "@ plus a non-blank tail; so
-- the recovered @name@ here is never empty.
parseTabRename :: [Text] -> Text -> Maybe Slash.SlashCommand
parseTabRename []        _    = Nothing
parseTabRename [_]       _    = Nothing
parseTabRename (n:_rest) line = do
  idx <- parseDecimalIndex n
  let afterRenameKw = stripLeadingWord "rename" line
      afterN        = stripLeadingWord n        afterRenameKw
      name          = T.strip afterN
  -- 'name' is non-empty by caller's invariant; guard preserved
  -- defensively.
  if T.null name
     then Nothing
     else Just (Slash.CmdTab (Slash.TabRenameCmd idx name))

-- | Drop a leading word (case-insensitive on alpha keywords; literal
-- match for non-alpha) plus its trailing whitespace from a 'Text'.
-- Returns the original 'Text' unchanged if the prefix is absent.
stripLeadingWord :: Text -> Text -> Text
stripLeadingWord w t =
  let lt   = T.toLower t
      lw   = T.toLower w
      lead = T.dropWhile isHSpace lt
      ofs  = T.length t - T.length lead
  in if lw `T.isPrefixOf` lead
       then T.dropWhile isHSpace (T.drop (ofs + T.length lw) t)
       else t

-- | Parse a strictly-decimal index, rejecting leading-zero forms per
-- the same disambiguation rule that 'parseDigitsForm' applies.
parseDecimalIndex :: Text -> Maybe Int
parseDecimalIndex t
  | T.null t                                  = Nothing
  | not (T.all Char.isDigit t)                = Nothing
  | T.length t > 1 && T.head t == '0'         = Nothing
  | otherwise = case TR.decimal t of
      Right (n, leftover) | T.null leftover -> Just n
      _                                     -> Nothing

-- | Recognise the short tab-kind keywords (case-insensitive).
parseTabKindArg :: Text -> Maybe Slash.TabKindArg
parseTabKindArg t = case T.toLower t of
  "ai"      -> Just Slash.TkaAi
  "harness" -> Just Slash.TkaHarness
  "shell"   -> Just Slash.TkaShell
  "ssh"     -> Just Slash.TkaSsh
  "tmux"    -> Just Slash.TkaTmux
  _         -> Nothing


-- ---------------------------------------------------------------------------
-- mkSessionId
-- ---------------------------------------------------------------------------

-- | Smart constructor for 'Core.SessionId' used by the @\/tab resume@
-- and @\/session resume@ parsers per S3 \/ P15a \/ L7.
--
-- Rejects:
--
--   * the empty string;
--   * any occurrence of @\/@ or @\\@ (path traversal);
--   * the substring @..@ (parent-dir reference);
--   * any NUL byte (@\\0@);
--   * any character outside the @[a-zA-Z0-9_-]@ corpus.
mkSessionId :: Text -> Either RT.ParseError Core.SessionId
mkSessionId t
  | T.null t                              = Left RT.ParseErrorInvalidSessionId
  | T.any (== '/')  t                     = Left RT.ParseErrorInvalidSessionId
  | T.any (== '\\') t                     = Left RT.ParseErrorInvalidSessionId
  | T.any (== '\0') t                     = Left RT.ParseErrorInvalidSessionId
  | ".." `T.isInfixOf` t                  = Left RT.ParseErrorInvalidSessionId
  | not (T.all isSessionIdChar t)         = Left RT.ParseErrorInvalidSessionId
  | otherwise = Right (Core.SessionId t)

-- | The @[a-zA-Z0-9_-]@ predicate used by 'mkSessionId'.
isSessionIdChar :: Char -> Bool
isSessionIdChar c =
     Char.isAsciiLower c
  || Char.isAsciiUpper c
  || Char.isDigit      c
  || c == '_'
  || c == '-'


-- ---------------------------------------------------------------------------
-- sanitizeTabName
-- ---------------------------------------------------------------------------

-- | Default length cap used by the bare 'sanitizeTabName'. Matches
-- 'RT.RoutingConfig._rc_maxNameLen' default. Exposed so test fixtures
-- can reference it directly.
defaultMaxNameLen :: Int
defaultMaxNameLen = 32

-- | Sanitize a user-supplied tab name per H11 / S10.
--
-- Equivalent to @'sanitizeTabNameWith' 'defaultMaxNameLen'@.
sanitizeTabName :: Text -> Either Tab.NameError Text
sanitizeTabName = sanitizeTabNameWith defaultMaxNameLen

-- | Sanitize a user-supplied tab name against an explicit length cap.
--
-- Pipeline (in order):
--
--   1. Reject inputs that contain ANSI escape sequences
--      (@\\x1b[@ \/ CSI @\\x9b@) — 'Tab.NameContainsAnsi'.
--   2. Reject inputs that contain control bytes (@\<0x20@ except
--      ordinary space) — 'Tab.NameContainsControlBytes'.
--   3. Reject inputs whose UTF-16 length exceeds the cap —
--      'Tab.NameTooLong'.
--   4. Run the redaction pipeline (paths → hostnames → IPv4 → ssh
--      stderr) from 'PureClaw.Internal.Redact'. If the result is empty
--      after trimming, surface 'Tab.NameRedactedToEmpty'.
--
-- The output is always a non-empty 'Text' satisfying the four
-- invariants asserted by the H11 property test.
sanitizeTabNameWith :: Int -> Text -> Either Tab.NameError Text
sanitizeTabNameWith cap raw
  | containsAnsi raw         = Left Tab.NameContainsAnsi
  | containsControlByte raw  = Left Tab.NameContainsControlBytes
  | T.length raw > cap       = Left Tab.NameTooLong
  | T.null trimmed           = Left Tab.NameRedactedToEmpty
  | otherwise                = Right trimmed
  where
    redacted = redactPipeline raw
    trimmed  = T.strip redacted

-- | The redaction pipeline; mirrors 'Redact.redactText' which is not
-- exported (only individual stage functions are). Order matches the
-- canonical pipeline: paths first, hostnames second, IPv4 third, ssh
-- stderr last.
redactPipeline :: Text -> Text
redactPipeline =
    Redact.redactSshStderr
  . Redact.redactIPv4
  . Redact.redactHostname
  . Redact.redactPath . T.unpack

-- | True if the input contains an ANSI \/ CSI escape introducer
-- (@ESC [@ or the 8-bit CSI byte @0x9B@).
containsAnsi :: Text -> Bool
containsAnsi t = "\ESC[" `T.isInfixOf` t || T.any (== '\x9B') t

-- | True if the input contains any byte below @0x20@ other than a
-- tab (@\\t@) or newline. We treat ordinary spaces (@0x20@) as
-- permitted; the H11 spec says "control bytes \< 0x20 except space"
-- which we read as: control bytes are forbidden whether or not the
-- containing whitespace-class is allowed. Tabs and newlines (the
-- two most common embedded controls) are rejected — a tab name is a
-- single-line label.
containsControlByte :: Text -> Bool
containsControlByte = T.any isReject
  where
    isReject c = c < ' ' && c /= ' '
