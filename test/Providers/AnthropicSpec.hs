module Providers.AnthropicSpec (spec) where

import Control.Monad (foldM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime)
import Network.HTTP.Client.TLS qualified as TLS
import Test.Hspec

import PureClaw.Auth.AnthropicOAuth
import PureClaw.Core.Types
import PureClaw.Providers.Anthropic
import PureClaw.Providers.Class
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "encodes a basic request as JSON" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "claude-sonnet-4-20250514"
            , _cr_messages     = [textMessage User "Hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Just 1024
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> do
          val `shouldSatisfy` hasKey "model"
          val `shouldSatisfy` hasKey "messages"
          val `shouldSatisfy` hasKey "max_tokens"

    it "includes system prompt when provided" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "claude-sonnet-4-20250514"
            , _cr_messages     = [textMessage User "Hi"]
            , _cr_systemPrompt = Just "Be helpful"
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` hasKey "system"

    it "omits system field when no system prompt" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` (not . hasKey "system")

    it "defaults max_tokens to 4096 when Nothing" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case KM.lookup "max_tokens" obj of
            Just (Number n) -> n `shouldBe` 4096
            _ -> expectationFailure "max_tokens not found or not a number"
        Just _ -> expectationFailure "Expected object"

    it "includes tools when provided" $ do
      let tool = ToolDefinition "shell" "Run a shell command" (object ["type" .= ("object" :: String)])
          req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = [tool]
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` hasKey "tools"

    it "omits tools when empty" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = []
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just val -> val `shouldSatisfy` (not . hasKey "tools")

    it "encodes messages with content block arrays" $ do
      let req = CompletionRequest
            { _cr_model        = ModelId "m"
            , _cr_messages     = [textMessage User "hello"]
            , _cr_systemPrompt = Nothing
            , _cr_maxTokens    = Nothing
            , _cr_tools        = []
            , _cr_toolChoice   = Nothing
            }
          body = encodeRequest req
      case decode body :: Maybe Value of
        Nothing -> expectationFailure "Invalid JSON"
        Just (Object obj) ->
          case KM.lookup "messages" obj of
            Just (Array msgs) -> do
              length msgs `shouldBe` 1
            _ -> expectationFailure "messages not found or not an array"
        Just _ -> expectationFailure "Expected object"

  describe "decodeResponse" $ do
    it "decodes a successful Anthropic response" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Hello!\"}]"
            , ",\"model\":\"claude-sonnet-4-20250514\""
            , ",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          _crsp_content resp `shouldBe` [TextBlock "Hello!"]
          _crsp_model resp `shouldBe` ModelId "claude-sonnet-4-20250514"
          _crsp_usage resp `shouldBe` Just (Usage 10 5)

    it "concatenates multiple text content blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Hello \"}"
            , ",{\"type\":\"text\",\"text\":\"world!\"}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> responseText resp `shouldBe` "Hello \nworld!"

    it "decodes tool_use content blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls\"}}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          let calls = toolUseCalls resp
          length calls `shouldBe` 1

    it "decodes mixed text and tool_use blocks" $ do
      let json = BL.fromStrict $ mconcat
            [ "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"}"
            , ",{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"shell\",\"input\":{\"command\":\"ls\"}}]"
            , ",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
            ]
      case decodeResponse json of
        Left err -> expectationFailure err
        Right resp -> do
          responseText resp `shouldBe` "Let me check."
          length (toolUseCalls resp) `shouldBe` 1

    it "returns error on invalid JSON" $ do
      decodeResponse "not json" `shouldSatisfy` isLeft

    it "returns error on missing fields" $ do
      decodeResponse "{\"content\":[]}" `shouldSatisfy` isLeft

  describe "AnthropicError" $ do
    it "has a Show instance" $ do
      show (AnthropicAPIError 401 "unauthorized") `shouldContain` "401"
      show (AnthropicParseError "bad json") `shouldContain` "bad json"

  describe "parseSSELine" $ do
    it "parses a data line with JSON" $ do
      let line = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}"
      parseSSELine line `shouldSatisfy` isJust

    it "returns Nothing for non-data lines" $ do
      parseSSELine "event: content_block_delta" `shouldBe` Nothing
      parseSSELine "" `shouldBe` Nothing

    it "returns Nothing for malformed JSON" $ do
      parseSSELine "data: not-json" `shouldBe` Nothing

    it "parses message_start events" $ do
      let line = "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-sonnet-4-20250514\",\"content\":[]}}"
      parseSSELine line `shouldSatisfy` isJust

  describe "stream accumulation" $ do
    it "accumulates a tool_use block from streamed events" $ do
      let resp = runStream toolOnlyStream
          calls = toolUseCalls resp
      length calls `shouldBe` 1
      case calls of
        [(_, name, input)] -> do
          name `shouldBe` "file_write"
          input `shouldBe` object
            [ "path"    .= ("/tmp/test.txt" :: Text)
            , "content" .= ("Hello" :: Text)
            ]
        _ -> expectationFailure "expected exactly one tool call"

    it "preserves text and tool blocks in stream order" $ do
      let resp = runStream mixedStream
      responseText resp `shouldBe` "Let me create the file."
      length (toolUseCalls resp) `shouldBe` 1

    it "accumulates multiple sequential tool blocks" $ do
      length (toolUseCalls (runStream twoToolsStream)) `shouldBe` 2

    it "emits StreamToolUse and StreamToolInput callbacks" $ do
      eventsRef <- newIORef ([] :: [StreamEvent])
      let cb e = modifyIORef eventsRef (e :)
      foldM_ (processStreamLine cb) initialStreamState toolOnlyStream
      events <- reverse <$> readIORef eventsRef
      events `shouldSatisfy` any isToolUseEvent
      events `shouldSatisfy` any isToolInputEvent

    it "captures both input and output token counts" $ do
      -- Regression: streaming used to hard-code input_tokens=0 because
      -- the parser only looked at message_delta.usage.output_tokens
      -- and ignored message_start.message.usage.input_tokens.
      _crsp_usage (runStream toolOnlyStream) `shouldBe` Just (Usage 12 7)

    it "reports Nothing for usage when no token events arrive" $ do
      _crsp_usage (runStream noUsageStream) `shouldBe` Nothing

    it "tolerates CRLF line endings" $
      let crlf = map (<> "\r") toolOnlyStream
      in length (toolUseCalls (runStream crlf)) `shouldBe` 1

    it "reassembles SSE events split across network chunks" $ do
      -- Concat the canned stream into one buffer (with newlines) and
      -- feed it through splitSSELines two bytes at a time, simulating
      -- a server that fragments mid-line. Output must equal the
      -- whole-stream parse.
      let joined  = BS.intercalate "\n" toolOnlyStream <> "\n"
          chunks  = chunkBy 2 joined
          drive (st, buf) chunk =
            let (ls, rest) = splitSSELines (buf <> chunk)
            in (foldl (\s l -> fst (runStreamLine l s)) st ls, rest)
          (final, _) = foldl drive (initialStreamState, BS.empty) chunks
          (resp, _) = finalizeStreamState final
      length (toolUseCalls resp) `shouldBe` 1
      _crsp_usage resp `shouldBe` Just (Usage 12 7)

    it "falls back to empty object on malformed tool input JSON" $ do
      -- Documents the silent-fallback behavior so a future change has
      -- to break this test deliberately.
      case toolUseCalls (runStream malformedToolStream) of
        [(_, _, input)] -> input `shouldBe` object []
        _               -> expectationFailure "expected one tool call"

    it "emits a StreamWarning when tool input JSON is malformed" $ do
      -- A silent fallback to empty input would let the agent loop run a
      -- tool call with bogus arguments and produce a confusing schema
      -- error. The warning carries the tool name and id so operators can
      -- correlate the failure with the request.
      eventsRef <- newIORef ([] :: [StreamEvent])
      let cb e = modifyIORef eventsRef (e :)
      foldM_ (processStreamLine cb) initialStreamState malformedToolStream
      events <- reverse <$> readIORef eventsRef
      let warnings = [t | StreamWarning t <- events]
      length warnings `shouldBe` 1
      case warnings of
        [w] -> do
          w `shouldSatisfy` (\t -> "toolu_01" `T.isInfixOf` t)
          w `shouldSatisfy` (\t -> "file_write" `T.isInfixOf` t)
        _   -> expectationFailure "expected exactly one warning"

  describe "buildAuthHeaders (API key)" $ do
    it "uses x-api-key header for ApiKey auth" $ do
      manager <- TLS.newTlsManager
      let provider = mkAnthropicProvider manager (mkApiKey "test-key")
      headers <- buildAuthHeaders provider
      let names = map fst headers
      names `shouldContain` ["x-api-key"]
      names `shouldNotContain` ["authorization"]

    it "includes anthropic-version header" $ do
      manager <- TLS.newTlsManager
      let provider = mkAnthropicProvider manager (mkApiKey "k")
      headers <- buildAuthHeaders provider
      map fst headers `shouldContain` ["anthropic-version"]

    it "does not include anthropic-beta header for API key auth" $ do
      manager <- TLS.newTlsManager
      let provider = mkAnthropicProvider manager (mkApiKey "k")
      headers <- buildAuthHeaders provider
      map fst headers `shouldNotContain` ["anthropic-beta"]

  describe "buildAuthHeaders (OAuth)" $ do
    it "uses Authorization: Bearer header for OAuth auth" $ do
      manager <- TLS.newTlsManager
      let futureExpiry = addUTCTime 3600 (UTCTime (fromGregorian 2099 1 1) 0)
          tokens = OAuthTokens
            { _oat_accessToken  = mkBearerToken "oauth-token"
            , _oat_refreshToken = "refresh"
            , _oat_expiresAt    = futureExpiry
            }
      handle <- mkOAuthHandle defaultOAuthConfig manager tokens
      let provider = mkAnthropicProviderOAuth manager handle
      headers <- buildAuthHeaders provider
      let names = map fst headers
      names `shouldContain` ["authorization"]
      names `shouldNotContain` ["x-api-key"]

    it "includes anthropic-beta header for OAuth auth" $ do
      manager <- TLS.newTlsManager
      let futureExpiry = addUTCTime 3600 (UTCTime (fromGregorian 2099 1 1) 0)
          tokens = OAuthTokens
            { _oat_accessToken  = mkBearerToken "tok"
            , _oat_refreshToken = "ref"
            , _oat_expiresAt    = futureExpiry
            }
      handle <- mkOAuthHandle defaultOAuthConfig manager tokens
      let provider = mkAnthropicProviderOAuth manager handle
      headers <- buildAuthHeaders provider
      map fst headers `shouldContain` ["anthropic-beta"]

    it "refreshes token when expired and uses new token" $ do
      manager <- TLS.newTlsManager
      let pastExpiry = UTCTime (fromGregorian 2020 1 1) 0
          freshExpiry = addUTCTime 3600 (UTCTime (fromGregorian 2099 1 1) 0)
          oldTokens = OAuthTokens
            { _oat_accessToken  = mkBearerToken "old-token"
            , _oat_refreshToken = "ref"
            , _oat_expiresAt    = pastExpiry
            }
          newTokens = OAuthTokens
            { _oat_accessToken  = mkBearerToken "new-token"
            , _oat_refreshToken = "ref2"
            , _oat_expiresAt    = freshExpiry
            }
      ref <- newIORef oldTokens
      let handle = OAuthHandle
            { _oah_tokensRef = ref
            , _oah_refresh   = \_ -> pure newTokens
            }
          provider = mkAnthropicProviderOAuth manager handle
      headers <- buildAuthHeaders provider
      let authVal = lookup "authorization" headers
      authVal `shouldBe` Just ("Bearer " <> "new-token")
      -- Confirm the ref was updated
      stored <- readIORef ref
      withBearerToken (_oat_accessToken stored) id `shouldBe` "new-token"

-- | Check if a JSON Value (assumed Object) contains a given key.
hasKey :: Key -> Value -> Bool
hasKey k (Object obj) = KM.member k obj
hasKey _ _ = False

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing = False

isToolUseEvent :: StreamEvent -> Bool
isToolUseEvent (StreamToolUse _ _) = True
isToolUseEvent _                   = False

isToolInputEvent :: StreamEvent -> Bool
isToolInputEvent (StreamToolInput _) = True
isToolInputEvent _                   = False

-- | Run a sequence of canned SSE lines through the pure stream pipeline
-- and return the finalized completion response. No IO, no IORefs.
runStream :: [ByteString] -> CompletionResponse
runStream =
  fst
    . finalizeStreamState
    . foldl' (\s line -> fst (runStreamLine line s)) initialStreamState

-- | Split a ByteString into fixed-size chunks (last chunk may be smaller).
chunkBy :: Int -> ByteString -> [ByteString]
chunkBy n bs
  | BS.null bs = []
  | otherwise  = let (h, t) = BS.splitAt n bs in h : chunkBy n t

-- | Realistic Anthropic SSE stream containing a single tool_use block
-- whose JSON input is split across two partial_json deltas.
toolOnlyStream :: [ByteString]
toolOnlyStream =
  [ "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-sonnet-4-20250514\",\"content\":[],\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}"
  , "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"file_write\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"/tmp/test.txt\\\",\\\"content\\\":\\\"Hello\\\"}\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":0}"
  , "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":7}}"
  , "data: {\"type\":\"message_stop\"}"
  ]

-- | A stream with no message_start usage and no message_delta usage —
-- exercises the @Nothing@ branch of finalize.
noUsageStream :: [ByteString]
noUsageStream =
  [ "data: {\"type\":\"message_start\",\"message\":{\"model\":\"m\",\"content\":[]}}"
  , "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":0}"
  , "data: {\"type\":\"message_stop\"}"
  ]

-- | A stream where the tool_use input JSON is malformed — exercises
-- the documented empty-object fallback.
malformedToolStream :: [ByteString]
malformedToolStream =
  [ "data: {\"type\":\"message_start\",\"message\":{\"model\":\"m\",\"content\":[]}}"
  , "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"file_write\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{not valid json\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":0}"
  , "data: {\"type\":\"message_stop\"}"
  ]

-- | Stream containing a text block followed by a tool_use block —
-- the most common shape when the model narrates before acting.
mixedStream :: [ByteString]
mixedStream =
  [ "data: {\"type\":\"message_start\",\"message\":{\"model\":\"m\",\"content\":[]}}"
  , "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me create the file.\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":0}"
  , "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"file_write\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/tmp/test.txt\\\"}\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":1}"
  , "data: {\"type\":\"message_stop\"}"
  ]

-- | Stream containing two sequential tool_use blocks — exercises the
-- builder being reset cleanly between blocks.
twoToolsStream :: [ByteString]
twoToolsStream =
  [ "data: {\"type\":\"message_start\",\"message\":{\"model\":\"m\",\"content\":[]}}"
  , "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"first\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":0}"
  , "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_02\",\"name\":\"second\"}}"
  , "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"b\\\":2}\"}}"
  , "data: {\"type\":\"content_block_stop\",\"index\":1}"
  , "data: {\"type\":\"message_stop\"}"
  ]

