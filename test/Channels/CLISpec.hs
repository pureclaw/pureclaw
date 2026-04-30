module Channels.CLISpec (spec) where

import Test.Hspec

import PureClaw.Channels.CLI

spec :: Spec
spec = do
  describe "mkCLIChannelHandle" $ do
    it "can be constructed" $ do
      -- mkCLIChannelHandle reads from stdin, so we can only test
      -- that it constructs without error. Interactive tests would
      -- require stdin/stdout redirection.
      mkCLIChannelHandle Nothing `seq` pure () :: IO ()
