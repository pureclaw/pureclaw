module Main where

import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "PureClaw" $ do
    it "placeholder" $ True `shouldBe` True
