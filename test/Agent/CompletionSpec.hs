module Agent.CompletionSpec (spec) where

import Test.Hspec

import PureClaw.Agent.Completion

spec :: Spec
spec = do
  describe "slashCompletions" $ do
    it "returns all commands for bare /" $ do
      let results = slashCompletions "/"
      results `shouldSatisfy` ("/help" `elem`)
      results `shouldSatisfy` ("/target" `elem`)
      results `shouldSatisfy` ("/vault" `elem`)
      results `shouldSatisfy` ("/harness" `elem`)
      results `shouldSatisfy` ("/transcript" `elem`)

    it "completes /pro to /provider" $ do
      slashCompletions "/pro" `shouldSatisfy` ("/provider" `elem`)

    it "completes /t to /target and /transcript" $ do
      slashCompletions "/t" `shouldSatisfy` ("/target" `elem`)

    it "completes /h to /harness and /help" $ do
      let results = slashCompletions "/h"
      results `shouldSatisfy` ("/harness" `elem`)
      results `shouldSatisfy` ("/help" `elem`)

    it "returns empty for non-slash input" $ do
      slashCompletions "hello" `shouldBe` []

    it "returns empty for empty input" $ do
      slashCompletions "" `shouldBe` []

    it "completes vault subcommands" $ do
      let results = slashCompletions "/vault "
      results `shouldSatisfy` ("setup" `elem`)
      results `shouldSatisfy` ("add" `elem`)
      results `shouldSatisfy` ("list" `elem`)
      results `shouldSatisfy` ("delete" `elem`)
      results `shouldSatisfy` ("lock" `elem`)
      results `shouldSatisfy` ("unlock" `elem`)
      results `shouldSatisfy` ("status" `elem`)

    it "completes vault subcommands with partial input" $ do
      let results = slashCompletions "/vault s"
      results `shouldSatisfy` ("setup" `elem`)
      results `shouldSatisfy` ("status" `elem`)
      results `shouldSatisfy` (not . ("list" `elem`))

    it "completes harness subcommands" $ do
      let results = slashCompletions "/harness "
      results `shouldSatisfy` ("start" `elem`)
      results `shouldSatisfy` ("stop" `elem`)
      results `shouldSatisfy` ("list" `elem`)
      results `shouldSatisfy` ("attach" `elem`)

    it "completes transcript subcommands" $ do
      let results = slashCompletions "/transcript "
      results `shouldSatisfy` ("search" `elem`)
      results `shouldSatisfy` ("path" `elem`)

    it "is case-insensitive" $ do
      slashCompletions "/PRO" `shouldSatisfy` ("/provider" `elem`)
      slashCompletions "/VAULT S" `shouldSatisfy` ("setup" `elem`)
