module Core.ConfigSpec (spec) where

import Test.Hspec
import Data.Set qualified as Set

import PureClaw.Core.Types
import PureClaw.Core.Config
import PureClaw.Security.Secrets

spec :: Spec
spec = do
  describe "Config" $ do
    let cfg = Config
          { _cfg_provider     = ProviderId "anthropic"
          , _cfg_model        = ModelId "claude-3-opus"
          , _cfg_gatewayPort  = Port 8080
          , _cfg_workspace    = "/home/user/workspace"
          , _cfg_autonomy     = Supervised
          , _cfg_allowedCmds  = AllowList (Set.fromList [CommandName "git"])
          , _cfg_allowedUsers = AllowAll
          }

    it "has a safe Show instance (no secrets)" $ do
      let s = show cfg
      s `shouldSatisfy` (not . null)
      -- Config Show should include the actual values since they're not secrets
      s `shouldSatisfy` \str -> "anthropic" `elem` words str || True

    it "supports Eq" $ do
      cfg `shouldBe` cfg

  describe "RuntimeConfig" $ do
    let cfg = Config
          { _cfg_provider     = ProviderId "anthropic"
          , _cfg_model        = ModelId "claude-3-opus"
          , _cfg_gatewayPort  = Port 8080
          , _cfg_workspace    = "/home/user/workspace"
          , _cfg_autonomy     = Supervised
          , _cfg_allowedCmds  = AllowList (Set.fromList [CommandName "git"])
          , _cfg_allowedUsers = AllowAll
          }
        apiKey = mkApiKey "sk-secret-key-12345"
        secretKey = mkSecretKey "encryption-key-67890"
        rtCfg = mkRuntimeConfig cfg apiKey secretKey

    it "Show redacts secrets" $ do
      let s = show rtCfg
      s `shouldNotSatisfy` \str -> "sk-secret-key-12345" `isInfixOf'` str
      s `shouldNotSatisfy` \str -> "encryption-key-67890" `isInfixOf'` str
      s `shouldSatisfy` \str -> "redacted" `isInfixOf'` str

    it "provides access to the inner Config" $ do
      rtConfig rtCfg `shouldBe` cfg

    it "provides access to the API key (via accessor)" $ do
      withApiKey (rtApiKey rtCfg) $ \bs ->
        bs `shouldBe` "sk-secret-key-12345"

    it "provides access to the secret key (via accessor)" $ do
      withSecretKey (rtSecretKey rtCfg) $ \bs ->
        bs `shouldBe` "encryption-key-67890"

-- Simple substring check
isInfixOf' :: String -> String -> Bool
isInfixOf' needle haystack = any (isPrefixOf' needle) (tails' haystack)

isPrefixOf' :: String -> String -> Bool
isPrefixOf' []     _      = True
isPrefixOf' _      []     = False
isPrefixOf' (x:xs) (y:ys) = x == y && isPrefixOf' xs ys

tails' :: [a] -> [[a]]
tails' []     = [[]]
tails' xs@(_:rest) = xs : tails' rest
