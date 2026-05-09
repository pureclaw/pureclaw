module Tools.SessionSearchSpec (spec) where

import Data.Aeson
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Tools.Registry
import PureClaw.Tools.SessionSearch

spec :: Spec
spec = do
  describe "sessionSearchTool" $ do
    it "has the correct tool name" $ do
      let (def', _) = sessionSearchTool mkNoOpLogHandle "/tmp/nonexistent"
      _td_name def' `shouldBe` "session_search"

    it "returns no matches for empty sessions dir" $ do
      tmpDir <- getTemporaryDirectory
      let dir = tmpDir </> "pureclaw-session-search-test"
      createDirectoryIfMissing True dir
      -- Clean
      entries <- listDirectory dir
      mapM_ (\f -> removePathForcibly (dir </> f)) entries
      let (_, handler) = sessionSearchTool mkNoOpLogHandle dir
          input = object ["query" .= ("nonexistent" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No matches"

    it "handles missing sessions directory gracefully" $ do
      let (_, handler) = sessionSearchTool mkNoOpLogHandle "/tmp/definitely-not-a-real-dir-xyz"
          input = object ["query" .= ("test" :: String)]
      (output, isErr) <- runTool handler input
      isErr `shouldBe` False
      T.unpack output `shouldContain` "No matches"

    it "rejects invalid JSON input" $ do
      let (_, handler) = sessionSearchTool mkNoOpLogHandle "/tmp"
          input = object ["wrong" .= ("value" :: String)]
      (_, isErr) <- runTool handler input
      isErr `shouldBe` True
