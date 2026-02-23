module Gateway.RoutesSpec (spec) where

import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

import PureClaw.Gateway.Auth
import PureClaw.Gateway.Routes
import PureClaw.Handles.Log
import PureClaw.Security.Pairing
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "mkApp" $ do
    describe "GET /health" $ do
      it "returns 200 with status ok" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
        (status, body) <- runApp app "GET" ["health"] [] ""
        status `shouldBe` status200
        case eitherDecode body of
          Left err -> expectationFailure err
          Right val -> val `shouldBe` object ["status" .= ("ok" :: String)]

    describe "POST /pair" $ do
      it "returns a token for a valid code" $ do
        ps <- mkPairingState defaultPairingConfig
        code <- generatePairingCode ps
        withPairingCode code $ \codeText -> do
          let app = mkApp ps mkNoOpLogHandle
              reqBody = encode (object ["code" .= codeText])
          (status, _) <- runApp app "POST" ["pair"] [] (LBS.toStrict reqBody)
          status `shouldBe` status200

      it "returns 400 for an invalid code" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
            reqBody = encode (object ["code" .= ("999999" :: String)])
        (status, body) <- runApp app "POST" ["pair"] [] (LBS.toStrict reqBody)
        status `shouldBe` status400
        case eitherDecode body of
          Left err -> expectationFailure err
          Right val -> val `shouldBe` object ["error" .= ("InvalidCode" :: String)]

      it "returns 400 for invalid JSON" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
        (status, _) <- runApp app "POST" ["pair"] [] "not json"
        status `shouldBe` status400

    describe "POST /webhook" $ do
      it "returns 401 without Authorization header" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
            reqBody = encode (object ["userId" .= ("u1" :: String), "content" .= ("hi" :: String)])
        (status, _) <- runApp app "POST" ["webhook"] [] (LBS.toStrict reqBody)
        status `shouldBe` status401

      it "returns 401 with an invalid token" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
            headers = [(hAuthorization, "Bearer fake-token")]
            reqBody = encode (object ["userId" .= ("u1" :: String), "content" .= ("hi" :: String)])
        (status, _) <- runApp app "POST" ["webhook"] headers (LBS.toStrict reqBody)
        status `shouldBe` status401

      it "returns 200 with a valid token and body" $ do
        ps <- mkPairingState defaultPairingConfig
        code <- generatePairingCode ps
        withPairingCode code $ \codeText -> do
          let pairReq = PairRequest codeText
          pairResult <- handlePairRequest ps "test" pairReq mkNoOpLogHandle
          case pairResult of
            Left err -> expectationFailure $ "pairing failed: " ++ show err
            Right (PairResponse tokenText) -> do
              let app = mkApp ps mkNoOpLogHandle
                  headers = [(hAuthorization, "Bearer " <> TE.encodeUtf8 tokenText)]
                  reqBody = encode (object ["userId" .= ("u1" :: String), "content" .= ("hi" :: String)])
              (status, body) <- runApp app "POST" ["webhook"] headers (LBS.toStrict reqBody)
              status `shouldBe` status200
              case eitherDecode body of
                Left err -> expectationFailure err
                Right val -> val `shouldBe` object ["status" .= ("received" :: String)]

    describe "unknown routes" $ do
      it "returns 404 for unknown paths" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
        (status, _) <- runApp app "GET" ["unknown"] [] ""
        status `shouldBe` status404

      it "returns 404 for wrong methods" $ do
        ps <- mkPairingState defaultPairingConfig
        let app = mkApp ps mkNoOpLogHandle
        (status, _) <- runApp app "DELETE" ["health"] [] ""
        status `shouldBe` status404

  describe "HealthResponse" $ do
    it "encodes to JSON" $
      encode (HealthResponse "ok") `shouldBe` encode (object ["status" .= ("ok" :: String)])

  describe "ErrorResponse" $ do
    it "encodes to JSON" $
      encode (ErrorResponse "test error") `shouldBe` encode (object ["error" .= ("test error" :: String)])

  describe "WebhookRequest" $ do
    it "decodes from JSON" $ do
      let json = encode (object ["userId" .= ("u1" :: String), "content" .= ("hello" :: String)])
      case eitherDecode json of
        Left err -> expectationFailure err
        Right (WebhookRequest uid content) -> do
          uid `shouldBe` "u1"
          content `shouldBe` "hello"

  describe "WebhookResponse" $ do
    it "encodes to JSON" $
      encode (WebhookResponse "received") `shouldBe` encode (object ["status" .= ("received" :: String)])

-- | Run a WAI application with a synthetic request and capture the response.
runApp :: Application -> Method -> [Text] -> RequestHeaders -> BS.ByteString -> IO (Status, LBS.ByteString)
runApp app method path headers body = do
  bodyRef <- newIORef (Just body)
  let getBody = do
        mb <- readIORef bodyRef
        case mb of
          Nothing -> pure BS.empty
          Just b  -> do
            writeIORef bodyRef Nothing
            pure b
      req = setRequestBodyChunks getBody defaultRequest
        { requestMethod = method
        , pathInfo = path
        , requestHeaders = headers
        }
  resultRef <- newIORef (status500, LBS.empty)
  _ <- app req $ \resp -> do
    let status = responseStatus resp
    bodyLbs <- extractResponseBody resp
    writeIORef resultRef (status, bodyLbs)
    pure ResponseReceived
  readIORef resultRef

-- | Extract the response body by running the streaming body into a builder.
extractResponseBody :: Response -> IO LBS.ByteString
extractResponseBody resp = do
  chunksRef <- newIORef ([] :: [Builder.Builder])
  let collect chunk = modifyIORef chunksRef (chunk :)
      flush = pure ()
  withBody resp collect flush
  chunks <- readIORef chunksRef
  pure (Builder.toLazyByteString (mconcat (reverse chunks)))

-- | Run the response body with a chunk collector.
withBody :: Response -> (Builder.Builder -> IO ()) -> IO () -> IO ()
withBody resp collect flush =
  case responseToStream resp of
    (_, _, withStream) -> withStream $ \streamBody ->
      streamBody collect flush
