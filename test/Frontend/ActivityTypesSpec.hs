-- | Tests for 'PureClaw.Frontend.Activity.Types'.
--
-- Covers the 'HarnessActivity' 'ToJSON' instances, including the
-- 'HarnessNeedsInput' constructor added in Task 3.
module Frontend.ActivityTypesSpec (spec) where

import Data.Aeson qualified as Aeson
import Test.Hspec

import PureClaw.Frontend.Activity.Types (HarnessActivity (..))

spec :: Spec
spec = do
  describe "HarnessActivity ToJSON" $ do
    it "encodes HarnessThinking as \"thinking\"" $
      Aeson.toJSON HarnessThinking `shouldBe` Aeson.String "thinking"

    it "encodes HarnessIdle as \"idle\"" $
      Aeson.toJSON HarnessIdle `shouldBe` Aeson.String "idle"

    it "encodes HarnessNeedsInput as \"needs-input\"" $
      Aeson.toJSON HarnessNeedsInput `shouldBe` Aeson.String "needs-input"

    it "encodes HarnessStopped as \"stopped\"" $
      Aeson.toJSON HarnessStopped `shouldBe` Aeson.String "stopped"
