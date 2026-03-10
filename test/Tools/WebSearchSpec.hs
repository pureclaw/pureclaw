module Tools.WebSearchSpec (spec) where

import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Network
import PureClaw.Providers.Class
import PureClaw.Security.Secrets
import PureClaw.Tools.Registry
import PureClaw.Tools.WebSearch

spec :: Spec
spec = do
  describe "webSearchTool" $ do
    let braveAllow = AllowList (Set.fromList ["api.search.brave.com"])
        testKey = mkApiKey "test-key-123"

    it "has the correct tool name" $ do
      let (def', _) = webSearchTool braveAllow testKey mkNoOpNetworkHandle
      _td_name def' `shouldBe` "web_search"

    it "makes a search request and formats results" $ do
      let mockResponse = BS8.pack $ unlines
            [ "{"
            , "  \"web\": {"
            , "    \"results\": ["
            , "      {"
            , "        \"title\": \"Haskell Language\","
            , "        \"url\": \"https://haskell.org\","
            , "        \"description\": \"An advanced purely functional language\""
            , "      },"
            , "      {"
            , "        \"title\": \"Learn Haskell\","
            , "        \"url\": \"https://learn.haskell.org\","
            , "        \"description\": \"Tutorials and guides\""
            , "      }"
            , "    ]"
            , "  }"
            , "}"
            ]
          mockNH = mkNoOpNetworkHandle
            { _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse
                { _hr_statusCode = 200
                , _hr_body = mockResponse
                }
            }
          (_, handler) = webSearchTool braveAllow testKey mockNH
          input = object ["query" .= ("haskell" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Haskell Language"
      T.unpack output `shouldContain` "https://haskell.org"
      T.unpack output `shouldContain` "Learn Haskell"

    it "handles empty results" $ do
      let mockNH = mkNoOpNetworkHandle
            { _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse
                { _hr_statusCode = 200
                , _hr_body = "{\"web\":{\"results\":[]}}"
                }
            }
          (_, handler) = webSearchTool braveAllow testKey mockNH
          input = object ["query" .= ("xyznonexistent" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No results"

    it "handles API errors" $ do
      let mockNH = mkNoOpNetworkHandle
            { _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse
                { _hr_statusCode = 401
                , _hr_body = "Unauthorized"
                }
            }
          (_, handler) = webSearchTool braveAllow testKey mockNH
          input = object ["query" .= ("test" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "HTTP 401"

    it "rejects when domain not in allow-list" $ do
      let emptyAllow = AllowList (Set.fromList ([] :: [T.Text]))
          (_, handler) = webSearchTool emptyAllow testKey mkNoOpNetworkHandle
          input = object ["query" .= ("test" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "not in allow-list"

    it "uses default count of 5" $ do
      let mockNH = mkNoOpNetworkHandle
            { _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse
                { _hr_statusCode = 200
                , _hr_body = "{\"web\":{\"results\":[]}}"
                }
            }
          (_, handler) = webSearchTool braveAllow testKey mockNH
          input = object ["query" .= ("test" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` False

    it "rejects invalid JSON input" $ do
      let (_, handler) = webSearchTool braveAllow testKey mkNoOpNetworkHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

    it "handles malformed JSON response" $ do
      let mockNH = mkNoOpNetworkHandle
            { _nh_httpGetWithHeaders = \_ _ -> pure HttpResponse
                { _hr_statusCode = 200
                , _hr_body = "not json"
                }
            }
          (_, handler) = webSearchTool braveAllow testKey mockNH
          input = object ["query" .= ("test" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Failed to parse"

  describe "escapeQuery" $ do
    it "escapes spaces as +" $ do
      escapeQuery "hello world" `shouldBe` "hello+world"

    it "escapes ampersands" $ do
      escapeQuery "a&b" `shouldBe` "a%26b"

    it "escapes percent signs" $ do
      escapeQuery "100%" `shouldBe` "100%25"

    it "passes through normal characters" $ do
      escapeQuery "haskell" `shouldBe` "haskell"

  describe "formatResults" $ do
    it "formats valid results" $ do
      let body = BS8.pack "{\"web\":{\"results\":[{\"title\":\"T\",\"url\":\"U\",\"description\":\"D\"}]}}"
      T.unpack (formatResults body) `shouldContain` "T"
      T.unpack (formatResults body) `shouldContain` "U"
      T.unpack (formatResults body) `shouldContain` "D"

    it "handles missing web key" $ do
      let body = BS8.pack "{\"other\":\"data\"}"
      T.unpack (formatResults body) `shouldContain` "No results"

    it "handles invalid JSON" $ do
      T.unpack (formatResults "not json") `shouldContain` "Failed to parse"
