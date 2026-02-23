module PureClaw.Security.Secrets
  ( -- * Secret types (constructors intentionally NOT exported)
    ApiKey
  , BearerToken
  , PairingCode
  , SecretKey
    -- * Smart constructors
  , mkApiKey
  , mkBearerToken
  , mkPairingCode
  , mkSecretKey
    -- * CPS-style accessors (prevents secret from escaping via binding)
  , withApiKey
  , withBearerToken
  , withPairingCode
  , withSecretKey
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

-- | API key for provider authentication.
-- Constructor unexported — use 'mkApiKey'.
-- No ToJSON, FromJSON, or ToTOML instances — secrets cannot be serialized.
newtype ApiKey = ApiKey ByteString

instance Show ApiKey where
  show _ = "ApiKey <redacted>"

-- | Bearer token for authenticated requests.
-- Constructor unexported — use 'mkBearerToken'.
newtype BearerToken = BearerToken ByteString

instance Show BearerToken where
  show _ = "BearerToken <redacted>"

-- | Pairing code for device/client pairing.
-- Constructor unexported — use 'mkPairingCode'.
newtype PairingCode = PairingCode Text

instance Show PairingCode where
  show _ = "PairingCode <redacted>"

-- | Secret key for encryption operations.
-- Constructor unexported — use 'mkSecretKey'.
newtype SecretKey = SecretKey ByteString

instance Show SecretKey where
  show _ = "SecretKey <redacted>"

-- Smart constructors

mkApiKey :: ByteString -> ApiKey
mkApiKey = ApiKey

mkBearerToken :: ByteString -> BearerToken
mkBearerToken = BearerToken

mkPairingCode :: Text -> PairingCode
mkPairingCode = PairingCode

mkSecretKey :: ByteString -> SecretKey
mkSecretKey = SecretKey

-- CPS-style accessors — the continuation receives the secret but cannot
-- store it without explicitly choosing to. This is safer than a direct
-- unwrap function because the secret's scope is limited to the continuation.

withApiKey :: ApiKey -> (ByteString -> r) -> r
withApiKey (ApiKey bs) f = f bs

withBearerToken :: BearerToken -> (ByteString -> r) -> r
withBearerToken (BearerToken bs) f = f bs

withPairingCode :: PairingCode -> (Text -> r) -> r
withPairingCode (PairingCode t) f = f t

withSecretKey :: SecretKey -> (ByteString -> r) -> r
withSecretKey (SecretKey bs) f = f bs
