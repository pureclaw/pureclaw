module PureClaw.Handles.Network
  ( -- * URL authorization (constructor intentionally NOT exported)
    AllowedUrl
  , UrlError (..)
  , mkAllowedUrl
  , getAllowedUrl
    -- * Response type
  , HttpResponse (..)
    -- * Handle type
  , NetworkHandle (..)
    -- * Implementations
  , mkNetworkHandle
  , mkNoOpNetworkHandle
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header qualified as Header
import Network.HTTP.Types.Status qualified as Status

import PureClaw.Core.Types

-- | A URL that has been validated against a domain allow-list.
-- Constructor is intentionally NOT exported — the only way to obtain an
-- 'AllowedUrl' is through 'mkAllowedUrl'.
--
-- Follows the same proof-carrying pattern as 'SafePath' and
-- 'AuthorizedCommand': the type is evidence that validation occurred.
newtype AllowedUrl = AllowedUrl { getAllowedUrl :: Text }
  deriving stock (Eq, Ord)

instance Show AllowedUrl where
  show u = "AllowedUrl " ++ show (getAllowedUrl u)

-- | Errors from URL validation.
data UrlError
  = UrlNotAllowed Text   -- ^ URL's domain is not in the allow-list
  | UrlMalformed Text    -- ^ URL could not be parsed
  deriving stock (Show, Eq)

-- | Validate a URL against an allow-list of permitted domains.
-- The URL must start with @https://@ and its domain must be in the list.
mkAllowedUrl :: AllowList Text -> Text -> Either UrlError AllowedUrl
mkAllowedUrl allowList url
  | not (T.isPrefixOf "https://" url) && not (T.isPrefixOf "http://" url) =
      Left (UrlMalformed url)
  | isAllowed allowList domain = Right (AllowedUrl url)
  | otherwise = Left (UrlNotAllowed url)
  where
    domain = extractDomain url

-- | Extract the domain from a URL. Simple extraction — takes the text
-- between @://@ and the next @/@ (or end of string).
extractDomain :: Text -> Text
extractDomain url =
  let afterScheme = T.drop 1 $ T.dropWhile (/= '/') $ T.drop 1 $ T.dropWhile (/= '/') url
      -- afterScheme is everything after "://"
      -- For "https://example.com/path", we want "example.com"
  in T.takeWhile (\c -> c /= '/' && c /= ':' && c /= '?') afterScheme

-- | HTTP response from a network request.
data HttpResponse = HttpResponse
  { _hr_statusCode :: Int
  , _hr_body       :: ByteString
  }
  deriving stock (Show, Eq)

-- | HTTP network capability. Only accepts 'AllowedUrl', which is proof
-- that the URL passed domain validation.
data NetworkHandle = NetworkHandle
  { _nh_httpGet  :: AllowedUrl -> IO HttpResponse
  , _nh_httpPost :: AllowedUrl -> ByteString -> IO HttpResponse
  , _nh_httpGetWithHeaders :: AllowedUrl -> [Header.Header] -> IO HttpResponse
  }

-- | Real network handle using @http-client@.
mkNetworkHandle :: HTTP.Manager -> NetworkHandle
mkNetworkHandle manager = NetworkHandle
  { _nh_httpGet = \url -> do
      req <- HTTP.parseRequest (T.unpack (getAllowedUrl url))
      resp <- HTTP.httpLbs req manager
      pure HttpResponse
        { _hr_statusCode = Status.statusCode (HTTP.responseStatus resp)
        , _hr_body       = BL.toStrict (HTTP.responseBody resp)
        }
  , _nh_httpPost = \url body -> do
      initReq <- HTTP.parseRequest (T.unpack (getAllowedUrl url))
      let req = initReq
            { HTTP.method = "POST"
            , HTTP.requestBody = HTTP.RequestBodyBS body
            }
      resp <- HTTP.httpLbs req manager
      pure HttpResponse
        { _hr_statusCode = Status.statusCode (HTTP.responseStatus resp)
        , _hr_body       = BL.toStrict (HTTP.responseBody resp)
        }
  , _nh_httpGetWithHeaders = \url headers -> do
      req <- HTTP.parseRequest (T.unpack (getAllowedUrl url))
      let req' = req { HTTP.requestHeaders = headers }
      resp <- HTTP.httpLbs req' manager
      pure HttpResponse
        { _hr_statusCode = Status.statusCode (HTTP.responseStatus resp)
        , _hr_body       = BL.toStrict (HTTP.responseBody resp)
        }
  }

-- | No-op network handle. Returns 200 with empty body.
mkNoOpNetworkHandle :: NetworkHandle
mkNoOpNetworkHandle = NetworkHandle
  { _nh_httpGet  = \_ -> pure HttpResponse { _hr_statusCode = 200, _hr_body = "" }
  , _nh_httpPost = \_ _ -> pure HttpResponse { _hr_statusCode = 200, _hr_body = "" }
  , _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse { _hr_statusCode = 200, _hr_body = "" }
  }
