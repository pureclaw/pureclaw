module Main where

import Test.Hspec

import qualified Core.TypesSpec
import qualified Core.ErrorsSpec
import qualified Core.ConfigSpec
import qualified Security.SecretsSpec
import qualified Security.PolicySpec
import qualified Security.PathSpec
import qualified Security.CommandSpec

main :: IO ()
main = hspec $ do
  describe "Core.Types" Core.TypesSpec.spec
  describe "Core.Errors" Core.ErrorsSpec.spec
  describe "Core.Config" Core.ConfigSpec.spec
  describe "Security.Secrets" Security.SecretsSpec.spec
  describe "Security.Policy" Security.PolicySpec.spec
  describe "Security.Path" Security.PathSpec.spec
  describe "Security.Command" Security.CommandSpec.spec
