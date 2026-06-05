-- | A validated, canonical UUID used to correlate a spawned @claude-code@
-- harness with its on-disk JSONL session-log file.
--
-- The value constructor is intentionally NOT exported. The only ways to
-- obtain a 'ClaudeSessionUuid' are:
--
--   * 'mkClaudeSessionUuid' — the smart constructor, which accepts ONLY a
--     canonical lowercase UUID (8-4-4-4-12, 36 chars).
--   * 'mintClaudeSessionUuid' — generates a fresh UUIDv4 from a
--     cryptographic source.
--   * the 'Aeson.FromJSON' instance, which routes through
--     'mkClaudeSessionUuid' so corrupted on-disk JSON cannot bypass
--     validation.
--
-- This mirrors the 'PureClaw.Session.Types.SessionPrefix' smart-constructor
-- pattern (newtype + typed error sum + validated 'FromJSON').
module PureClaw.Harness.ClaudeSession
  ( -- * Validated UUID (smart constructor)
    -- The data constructor is intentionally NOT exported.
    ClaudeSessionUuid
  , unClaudeSessionUuid
  , mkClaudeSessionUuid
  , ClaudeSessionUuidError (..)
    -- * Cryptographic generation
  , mintClaudeSessionUuid
  ) where

import Crypto.Random qualified as CR
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

-- | A validated canonical UUID correlating a @claude-code@ harness with its
-- JSONL session log. Always holds a canonical lowercase 36-character UUID.
--
-- The 'Show' instance is deliberately REDACTED: it never prints the raw uuid
-- into general logs. Use 'unClaudeSessionUuid' for the raw value when a caller
-- legitimately needs it (e.g. to build the log path).
newtype ClaudeSessionUuid = ClaudeSessionUuid Text
  deriving stock (Eq, Ord)

-- | Redacted 'Show'. Never leaks the raw uuid into general logs. (D1.4)
instance Show ClaudeSessionUuid where
  show _ = "ClaudeSessionUuid <redacted>"

-- | Explicit accessor for the raw canonical uuid text. Use only where the
-- raw value is genuinely required (e.g. constructing the JSONL log path).
unClaudeSessionUuid :: ClaudeSessionUuid -> Text
unClaudeSessionUuid (ClaudeSessionUuid t) = t

-- | Reasons a raw 'Text' cannot be promoted to a 'ClaudeSessionUuid'.
-- Mirrors 'PureClaw.Session.Types.SessionPrefixError'.
data ClaudeSessionUuidError
  = -- | The input was empty.
    UuidEmpty
  | -- | The input was not exactly 36 characters.
    UuidWrongLength
  | -- | The input was 36 characters but not a canonical lowercase UUID
    -- (wrong charset, uppercase hex, wrong hyphen positions, contains
    -- @\'\/\'@, @\"..\"@, NUL, etc.). Carries the offending input.
    UuidNotCanonical Text
  deriving stock (Show, Eq)

-- | Canonical UUID length: 8-4-4-4-12 plus four hyphens = 36 characters.
uuidLength :: Int
uuidLength = 36

-- | Zero-based positions of the four hyphens in a canonical UUID.
hyphenPositions :: [Int]
hyphenPositions = [8, 13, 18, 23]

-- | True iff the character is a lowercase hex digit (@0-9@, @a-f@).
-- Uppercase is intentionally rejected (reject-unless-already-canonical).
isLowerHexDigit :: Char -> Bool
isLowerHexDigit c = Char.isDigit c || (c >= 'a' && c <= 'f')

-- | True iff the character at the given zero-based position is valid for a
-- canonical UUID: a hyphen at a hyphen position, a lowercase hex digit
-- everywhere else.
isValidAtPos :: Int -> Char -> Bool
isValidAtPos pos c =
  if pos `elem` hyphenPositions
    then c == '-'
    else isLowerHexDigit c

-- | Smart constructor. Accepts ONLY a canonical lowercase UUID in the
-- @8-4-4-4-12@ (36-character) form. Rejects uppercase, wrong length, wrong
-- charset, wrong hyphen positions, and — by construction — any input
-- containing @\'\/\'@, @\"..\"@, or NUL bytes (none of those are valid
-- lowercase-hex-or-hyphen characters in the right positions).
--
-- The policy is reject-unless-already-canonical: an uppercase or otherwise
-- non-canonical UUID is REJECTED, not normalized, so the stored value is a
-- single canonical form that is safe to use directly in a filesystem path.
mkClaudeSessionUuid :: Text -> Either ClaudeSessionUuidError ClaudeSessionUuid
mkClaudeSessionUuid raw
  | T.null raw = Left UuidEmpty
  | T.length raw /= uuidLength = Left UuidWrongLength
  | not isCanonical = Left (UuidNotCanonical raw)
  | otherwise = Right (ClaudeSessionUuid raw)
  where
    isCanonical = all (uncurry isValidAtPos) (zip [0 ..] (T.unpack raw))

-- | Custom 'FromJSON' routes through 'mkClaudeSessionUuid' so corrupted
-- on-disk JSON cannot bypass the smart constructor. (D1.3)
instance FromJSON ClaudeSessionUuid where
  parseJSON = Aeson.withText "ClaudeSessionUuid" $ \t ->
    case mkClaudeSessionUuid t of
      Right u -> pure u
      Left e -> fail ("invalid ClaudeSessionUuid: " <> show e)

-- | 'ToJSON' renders the canonical uuid text. Round-trips with 'FromJSON'.
-- (D1.3)
instance ToJSON ClaudeSessionUuid where
  toJSON = toJSON . unClaudeSessionUuid

-- | Generate a fresh canonical UUIDv4 from a CRYPTOGRAPHIC source. (D1.2)
--
-- We draw 16 random bytes from 'Crypto.Random.getRandomBytes' (the @crypton@
-- CSPRNG, the same system-entropy source used elsewhere in this codebase for
-- key/IV/pairing-token generation — see "PureClaw.Security.Crypto"). We set
-- the RFC 4122 version (4) and variant (10xx) bits, then render the bytes
-- directly as canonical lowercase hex with hyphens at the 8-4-4-4-12
-- boundaries. We deliberately do NOT use @System.Random@'s default 'StdGen',
-- which is not a CSPRNG.
--
-- Construction is total and branch-free: 16 bytes always render to exactly
-- 36 canonical characters, so no error path is possible.
mintClaudeSessionUuid :: IO ClaudeSessionUuid
mintClaudeSessionUuid = do
  raw <- CR.getRandomBytes 16 :: IO ByteString
  let bytes = BS.pack (setVersionVariant (BS.unpack raw))
  pure (ClaudeSessionUuid (renderCanonical bytes))

-- | Force the RFC 4122 version (4) and variant (10xx) bits on the 16-byte
-- UUID payload so the result is a well-formed version-4 UUID.
setVersionVariant :: [Word8] -> [Word8]
setVersionVariant = zipWith adjust [0 :: Int ..]
  where
    adjust 6 b = (b .&. 0x0f) .|. 0x40 -- version 4 in the high nibble
    adjust 8 b = (b .&. 0x3f) .|. 0x80 -- variant 10xx in the high bits
    adjust _ b = b

-- | Render exactly 16 bytes as a canonical lowercase UUID: 32 lowercase hex
-- digits (via @base16-bytestring@) with hyphens inserted at the 8-4-4-4-12
-- boundaries. Total: 16 bytes always produce 32 hex chars, which split into
-- the canonical groups.
renderCanonical :: ByteString -> Text
renderCanonical bytes =
  let hex = TE.decodeLatin1 (B16.encode bytes) -- 32 lowercase hex chars
      (g1, r1) = T.splitAt 8 hex
      (g2, r2) = T.splitAt 4 r1
      (g3, r3) = T.splitAt 4 r2
      (g4, g5) = T.splitAt 4 r3
   in T.intercalate "-" [g1, g2, g3, g4, g5]
