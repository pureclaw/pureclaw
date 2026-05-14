-- |
-- Module      : PureClaw.Internal.Redact
-- Description : Redaction helpers for backend error \/ exception 'Show' (WU2).
--
-- All hand-written 'Show' instances in @PureClaw.Handles.Backend@
-- (notably for 'BackendError' and 'BackendException') route through
-- this module so the rendered output never leaks raw hostnames, IPv4
-- addresses, absolute filesystem paths, identity-file basenames, or
-- ssh stderr fragments.
--
-- The matching is intentionally pure-'Text', no regex dependency:
-- every replacement is a left-to-right scan that consumes a token at
-- a time. This makes the redactor easy to property-test (see
-- @test\/Internal\/RedactSpec.hs@) and keeps it usable from the
-- redacted 'Show' instances (no 'IO', no transitive deps).
--
-- See @docs\/terminal-backend-abstractions.md@ § \"Error Model\" and
-- § \"Information Disclosure / Redaction\".
module PureClaw.Internal.Redact
  ( -- * Error redaction
    redactErr
  , redactBackendError
  , redactBackendException
    -- * String bridge used by 'Show' instances inside the import cycle
  , redactedShowString
    -- * Token-level helpers (exposed for property tests + reuse)
  , redactPath
  , redactHostname
  , redactIPv4
  , redactSshStderr
    -- * Credential prompt scrubber
  , credentialPromptScrubber
  ) where

import Control.Applicative ((<|>))
import Control.Exception qualified as Exception
import Control.Exception (SomeException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)

import PureClaw.Handles.Backend
  ( BackendContext
  , BackendError (..)
  , BackendException (..)
  )

-- | Redact a 'SomeException' to a 'Text' safe for logs and 'Show'.
--
-- The pipeline is, in order: ssh stderr fragments → IPv4 addresses
-- → hostnames → absolute filesystem paths. Each step is idempotent
-- and operates on whatever the previous step produced. Order matters:
-- ssh-stderr replacement first so its embedded hostnames are wiped
-- as part of the fixed fragment, not split mid-token.
redactErr :: SomeException -> Text
redactErr e = redactText (T.pack (Exception.displayException e))

-- | The shared pipeline used by 'redactErr' and 'redactBackendException'.
--
-- Composition order matters: paths run FIRST (greedy on @/seg/seg/seg@),
-- otherwise a path whose segment names contain dots (e.g.
-- @/var/log/app.example/x@) would be partially eaten by
-- 'redactHostname' before 'redactPathText' ever sees it. After paths
-- are replaced, hostnames and IPv4 are safe to apply (their patterns
-- do not match the @\<path\>@ placeholder), and ssh-stderr fragments
-- are matched last so any hostname / IPv4 embedded in their fixed
-- vocabulary is already gone.
redactText :: Text -> Text
redactText = redactSshStderr . redactIPv4 . redactHostname . redactPathText

-- | Run an already-stringified payload (e.g. produced by 'show' on a
-- leaf ADT) through the same redaction pipeline 'redactErr' uses.
--
-- Exposed via the @.hs-boot@ so 'PureClaw.Handles.Backend'\'s
-- hand-written 'Show' instances for 'BackendError' \/
-- 'BackendException' can route through the redactor without
-- re-introducing the import cycle that pattern-matching on those
-- types here would create.
redactedShowString :: String -> Text
redactedShowString = redactText . T.pack

-- | Redact a 'BackendError' by emitting a redaction-safe summary for
-- each constructor. The inner ADT payloads are already redaction-safe
-- (closed sums or short fixed-vocabulary 'InvalidOptionDetail' text),
-- so it is enough to render the constructor name plus the inner
-- 'Show'.
redactBackendError :: BackendError -> Text
redactBackendError e = case e of
  BackendBinaryNotFound c ->
    T.pack ("BackendBinaryNotFound " <> show c)
  BackendPtyAllocFailed f ->
    T.pack ("BackendPtyAllocFailed " <> show f)
  BackendSshConnectFailed f ->
    T.pack ("BackendSshConnectFailed " <> show f)
  BackendTmuxTargetMissing t ->
    -- 'TmuxTargetRef' carries the (validated) session/window names; the
    -- contained Text was produced by the WU10 smart constructors and
    -- never contains shell metacharacters, but the names themselves
    -- could resemble hostnames (e.g. @prod-db.example.com@). Run the
    -- redaction pipeline over the Show form for defence in depth.
    redactText (T.pack ("BackendTmuxTargetMissing " <> show t))
  BackendInvalidOption d ->
    T.pack ("BackendInvalidOption " <> show d)
  BackendBufferQuotaExceeded n ->
    T.pack ("BackendBufferQuotaExceeded " <> show n)
  BackendBrokenTmuxTarget t ->
    redactText (T.pack ("BackendBrokenTmuxTarget " <> show t))

-- | Redact a 'BackendException' by formatting the context tag and
-- pushing the wrapped 'SomeException' through 'redactErr'.
redactBackendException :: BackendException -> Text
redactBackendException be =
  "BackendException { _be_context = "
    <> showContext (_be_context be)
    <> ", _be_cause = "
    <> redactErr (_be_cause be)
    <> " }"
  where
    showContext :: BackendContext -> Text
    showContext = T.pack . show

-- ---------------------------------------------------------------------------
-- Token-level helpers
-- ---------------------------------------------------------------------------

-- | Replace each ssh stderr fragment (case-insensitive substring
-- match) with @\<ssh-error\>@. The fixed list intentionally covers
-- the OpenSSH messages most likely to embed hostnames or paths.
redactSshStderr :: Text -> Text
redactSshStderr =
  replaceAnyCI sshStderrFragments "<ssh-error>"

-- | Patterns recognised as ssh stderr — matched case-insensitively
-- as plain substrings (not regex).
sshStderrFragments :: [Text]
sshStderrFragments =
  [ "Host key verification failed"
  , "Could not resolve hostname"
  , "Network is unreachable"
  , "Operation timed out"
  , "Connection timed out"
  , "Connection refused"
  , "Connection reset"
  , "No route to host"
  , "Permission denied"
  ]

-- | Replace dotted-quad IPv4 addresses with @\<ipv4\>@. Tokens with
-- four 1–3-digit groups separated by literal dots.
redactIPv4 :: Text -> Text
redactIPv4 = scanReplace stepIPv4

stepIPv4 :: Text -> Maybe (Int, Text)
stepIPv4 t = do
  (g1, r1) <- consumeOctet t
  r1'      <- T.stripPrefix "." r1
  (g2, r2) <- consumeOctet r1'
  r2'      <- T.stripPrefix "." r2
  (g3, r3) <- consumeOctet r2'
  r3'      <- T.stripPrefix "." r3
  (g4, _)  <- consumeOctet r3'
  let consumed = g1 + 1 + g2 + 1 + g3 + 1 + g4
  pure (consumed, "<ipv4>")
  where
    consumeOctet :: Text -> Maybe (Int, Text)
    consumeOctet s =
      let (ds, rest) = T.span Char.isDigit s
          n         = T.length ds
      in if n >= 1 && n <= 3 then Just (n, rest) else Nothing

-- | Replace tokens that look like RFC-1123 hostnames (have at least
-- one internal dot, are not purely numeric, and contain only
-- letters/digits/@.@/@-@) with @\<host\>@.
--
-- Tokens like @tmux@ (no dot) or @0@ (numeric) are left alone.
redactHostname :: Text -> Text
redactHostname = scanReplace stepHostname

stepHostname :: Text -> Maybe (Int, Text)
stepHostname t =
  let (tok, _) = T.span isHostByte t
      n        = T.length tok
  in if looksLikeHostname tok && n > 0
       then Just (n, "<host>")
       else Nothing
  where
    isHostByte :: Char -> Bool
    isHostByte c = Char.isAscii c && (Char.isAlphaNum c || c == '.' || c == '-')

-- | A token is a hostname-y string when it
--
-- * has length >= 3,
-- * contains at least one @.@,
-- * has neither leading nor trailing @.@ or @-@,
-- * is not purely composed of digits and dots (that\'s an IPv4-ish
--   string already handled by 'redactIPv4'),
-- * every dot-separated label is non-empty and starts\/ends with an
--   alnum.
looksLikeHostname :: Text -> Bool
looksLikeHostname tok
  | T.length tok < 3 = False
  | T.head tok == '.' || T.head tok == '-' = False
  | T.last tok == '.' || T.last tok == '-' = False
  | not (T.any (== '.') tok) = False
  | T.all (\c -> Char.isDigit c || c == '.') tok = False
  | otherwise = all labelOk (T.split (== '.') tok)
  where
    labelOk :: Text -> Bool
    labelOk lbl =
      not (T.null lbl)
        && Char.isAlphaNum (T.head lbl)
        && Char.isAlphaNum (T.last lbl)

-- | Replace absolute filesystem paths (tokens beginning with @\/@
-- followed by one or more path-safe characters) with @\<path\>@.
--
-- The path-safe charset is @[A-Za-z0-9_.\/-]@, matching the
-- regex-equivalent @\/[A-Za-z0-9_.\/-]+@.
redactPath :: FilePath -> Text
redactPath = redactPathText . T.pack

redactPathText :: Text -> Text
redactPathText = scanReplace stepPath

stepPath :: Text -> Maybe (Int, Text)
stepPath t = case T.uncons t of
  Just ('/', rest) ->
    let (body, _) = T.span isPathByte rest
        n         = T.length body
    in if n > 0 then Just (n + 1, "<path>") else Nothing
  _ -> Nothing
  where
    isPathByte :: Char -> Bool
    isPathByte c =
      Char.isAlphaNum c || c == '_' || c == '.' || c == '/' || c == '-'

-- ---------------------------------------------------------------------------
-- Generic scan-replace machinery
-- ---------------------------------------------------------------------------

-- | Left-to-right scan: at each position, the step function either
-- recognises a token (returning its byte length and the replacement
-- text) or yields 'Nothing', in which case the current character is
-- copied through and the scan advances by one.
scanReplace :: (Text -> Maybe (Int, Text)) -> Text -> Text
scanReplace step = go mempty
  where
    go acc t
      | T.null t = acc
      | otherwise = case step t of
          Just (n, replacement) ->
            go (acc <> replacement) (T.drop n t)
          Nothing -> case T.uncons t of
            Just (c, rest) -> go (acc <> T.singleton c) rest
            Nothing        -> acc

-- | Replace any (case-insensitive) substring from the needle list with
-- the given replacement. First match wins per scan step.
replaceAnyCI :: [Text] -> Text -> Text -> Text
replaceAnyCI needles replacement = scanReplace step
  where
    lowered :: [(Text, Int)]
    lowered = [(T.toLower n, T.length n) | n <- needles]
    step :: Text -> Maybe (Int, Text)
    step t =
      let lt = T.toLower t
          tryOne (n, len)
            | n `T.isPrefixOf` lt = Just (len, replacement)
            | otherwise = Nothing
      in firstJust (map tryOne lowered)

    firstJust :: [Maybe a] -> Maybe a
    firstJust = foldr (<|>) Nothing

-- ---------------------------------------------------------------------------
-- Credential prompt scrubber
-- ---------------------------------------------------------------------------

-- | Scrub credential prompts in a 'ByteString' chunk.
--
-- The scrubber scans left-to-right for any of the known prompt
-- patterns (case-insensitive on @password:@ \/ @passphrase:@; literal
-- on the other two). When a match is found, the matched trigger is
-- preserved verbatim and everything from the byte immediately
-- following the trigger up to the next newline (or end of chunk) is
-- replaced with the literal sentinel @[REDACTED]@.
--
-- This is stateless across calls; the overlap-window carry-forward
-- across chunk boundaries lives in the drainer (WU7).
credentialPromptScrubber :: ByteString -> ByteString
credentialPromptScrubber = go
  where
    go :: ByteString -> ByteString
    go bs = case firstPromptMatch bs of
      Nothing -> bs
      Just (start, len) ->
        let (before, fromMatch) = BS.splitAt start bs
            (matched, afterMatch) = BS.splitAt len fromMatch
            (line, rest) = BS.break (== 0x0A) afterMatch
            redactedLine
              | BS.null line = BS.empty
              | otherwise = sentinel
        in before <> matched <> redactedLine <> go rest

    sentinel :: ByteString
    sentinel = BSC.pack "[REDACTED]"

-- | Locate the first credential prompt occurrence: returns its
-- starting offset and the length of the matched trigger.
firstPromptMatch :: ByteString -> Maybe (Int, Int)
firstPromptMatch bs = bestOf
  [ findCI (BSC.pack "password:")          bs
  , findCI (BSC.pack "passphrase:")        bs
  , findLit (BSC.pack "[sudo] password for ") bs
  , findLit (BSC.pack "Sorry, try again")  bs
  ]
  where
    bestOf :: [Maybe (Int, Int)] -> Maybe (Int, Int)
    bestOf = foldr keepEarliest Nothing
      where
        keepEarliest Nothing acc = acc
        keepEarliest (Just x) Nothing = Just x
        keepEarliest (Just x@(a, _)) (Just y@(b, _))
          | a <= b = Just x
          | otherwise = Just y

    findLit :: ByteString -> ByteString -> Maybe (Int, Int)
    findLit needle hay =
      let (pre, post) = BS.breakSubstring needle hay
      in if BS.null post
           then Nothing
           else Just (BS.length pre, BS.length needle)

    findCI :: ByteString -> ByteString -> Maybe (Int, Int)
    findCI needle hay =
      let lneedle = lowerAscii needle
          lhay    = lowerAscii hay
          (pre, post) = BS.breakSubstring lneedle lhay
      in if BS.null post
           then Nothing
           else Just (BS.length pre, BS.length needle)

    lowerAscii :: ByteString -> ByteString
    lowerAscii = BS.map toLowerByte

    toLowerByte :: Word8 -> Word8
    toLowerByte w
      | w >= 0x41 && w <= 0x5A = w + 0x20
      | otherwise = w
