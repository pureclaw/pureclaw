module Tools.WebExtractSpec (spec) where

import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.Network
import PureClaw.Providers.Class
import PureClaw.Tools.Registry
import PureClaw.Tools.WebExtract

spec :: Spec
spec = do
  describe "webExtractTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = webExtractTool AllowAll mkNoOpNetworkHandle
      _td_name def' `shouldBe` "web_extract"

    it "fetches a URL and returns content" $ do
      let nh = mockNetwork 200 "Hello, world!"
          (_, handler) = webExtractTool AllowAll nh
          input = object ["url" .= ("https://example.com" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Hello, world!"

    it "converts HTML to readable text" $ do
      let html = "<html><body><h1>Title</h1><p>Some text</p></body></html>"
          nh = mockNetwork 200 html
          (_, handler) = webExtractTool AllowAll nh
          input = object ["url" .= ("https://example.com" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "# Title"
      T.unpack output `shouldContain` "Some text"

    it "strips script and style tags" $ do
      let html = "<html><head><style>body{}</style></head><body><script>alert(1)</script>Real content</body></html>"
          nh = mockNetwork 200 html
          (_, handler) = webExtractTool AllowAll nh
          input = object ["url" .= ("https://example.com" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "Real content"
      T.unpack output `shouldSatisfy` (not . ("alert" `elem`) . words)
      T.unpack output `shouldSatisfy` (not . ("body{}" `elem`) . words)

    it "reports HTTP errors" $ do
      let nh = mockNetwork 404 "Not found"
          (_, handler) = webExtractTool AllowAll nh
          input = object ["url" .= ("https://example.com/missing" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` True
      T.unpack output `shouldContain` "404"

    it "truncates large responses" $ do
      let bigBody = T.replicate 200000 "x"
          nh = mockNetwork 200 (T.unpack bigBody)
          (_, handler) = webExtractTool AllowAll nh
          input = object ["url" .= ("https://example.com" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "truncated"

    it "respects custom max_length" $ do
      let body = T.replicate 1000 "x"
          nh = mockNetwork 200 (T.unpack body)
          (_, handler) = webExtractTool AllowAll nh
          input = object
            [ "url" .= ("https://example.com" :: String)
            , "max_length" .= (500 :: Int)
            ]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "truncated"

    it "rejects invalid JSON input" $ do
      let (_, handler) = webExtractTool AllowAll mkNoOpNetworkHandle
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True

  describe "htmlToMarkdown" $ do
    it "converts headings" $ do
      let result = htmlToMarkdown "<h1>Title</h1><h2>Sub</h2>"
      T.unpack result `shouldContain` "# Title"
      T.unpack result `shouldContain` "## Sub"

    it "converts lists" $ do
      let result = htmlToMarkdown "<ul><li>One</li><li>Two</li></ul>"
      T.unpack result `shouldContain` "- One"
      T.unpack result `shouldContain` "- Two"

    it "converts emphasis" $ do
      let result = htmlToMarkdown "<strong>bold</strong> and <em>italic</em>"
      T.unpack result `shouldContain` "**bold**"
      T.unpack result `shouldContain` "*italic*"

    it "decodes HTML entities" $ do
      let result = htmlToMarkdown "5 &gt; 3 &amp; 2 &lt; 4"
      T.unpack result `shouldContain` "5 > 3 & 2 < 4"

    it "handles non-HTML input" $ do
      truncateBody 100 "short" `shouldBe` "short"
      T.unpack (truncateBody 5 "hello world") `shouldContain` "truncated"

-- | Create a mock network handle that returns a fixed response.
mockNetwork :: Int -> String -> NetworkHandle
mockNetwork status body = mkNoOpNetworkHandle
  { _nh_httpGet = \_ -> pure HttpResponse
      { _hr_statusCode = status
      , _hr_body = BS8.pack body
      }
  }
