-- | Verifies that the test suite stores all PureClaw data in an isolated
-- location under @\/tmp@, never the developer's real @~\/.pureclaw@.
--
-- The whole point of this spec is to fail loudly if the global test-home
-- isolation (set up in "Main") ever regresses, because a regression would
-- silently pollute a real PureClaw install running on the same machine.
module Support.IsolationSpec (spec) where

import Data.List (isPrefixOf)
import System.Environment (lookupEnv)
import Test.Hspec

import PureClaw.CLI.Config (getPureclawDir)

spec :: Spec
spec = describe "test storage isolation" $ do
  it "points HOME at an isolated /tmp directory" $ do
    mHome <- lookupEnv "HOME"
    mHome `shouldSatisfy` maybe False ("/tmp/" `isPrefixOf`)

  it "resolves getPureclawDir under /tmp, never the real user home" $ do
    dir <- getPureclawDir
    dir `shouldSatisfy` ("/tmp/" `isPrefixOf`)
