-- |
-- Module      : Tab.ContainerSpec
-- Description : WU-10 — Container + Local harness factory arms.
--
-- Tests for container exec argv construction, args denylist, engine-to-binary
-- mapping, flavour-to-binary mapping, and _h_cwd validation.
module Tab.ContainerSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Session.Kind
  ( ContainerEngine (..)
  , ContainerSpec (..)
  , ContainerTarget
  , HarnessFlavour (..)
  , mkContainerTarget
  )
import PureClaw.Tab.Container
  ( ContainerArgsError (..)
  , CwdError (..)
  , checkContainerArgs
  , containerArgsDenylist
  , containerEngineBinary
  , buildContainerExecArgv
  , flavourToBinary
  , validateCwd
  )


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Build a ContainerTarget from raw text; 'error' on failure (tests only
-- provide valid targets).
unsafeTarget :: Text -> ContainerTarget
unsafeTarget t = case mkContainerTarget t of
  Right ct -> ct
  Left e   -> error ("unsafeTarget: " <> show e)


-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "containerArgsDenylist" $ do
    it "is a non-empty list" $ do
      containerArgsDenylist `shouldSatisfy` (not . null)

    it "contains --privileged" $ do
      containerArgsDenylist `shouldSatisfy` elem "--privileged"

    it "contains --cap-add" $ do
      containerArgsDenylist `shouldSatisfy` elem "--cap-add"

    it "contains --security-opt" $ do
      containerArgsDenylist `shouldSatisfy` elem "--security-opt"

    it "contains --volume and -v" $ do
      containerArgsDenylist `shouldSatisfy` elem "--volume"
      containerArgsDenylist `shouldSatisfy` elem "-v"

    it "contains --mount" $ do
      containerArgsDenylist `shouldSatisfy` elem "--mount"

  describe "checkContainerArgs" $ do
    it "rejects [\"--privileged\"]" $ do
      checkContainerArgs ["--privileged"] `shouldBe`
        Left (DeniedFlag "--privileged")

    it "rejects [\"--cap-add\", \"SYS_ADMIN\"]" $ do
      checkContainerArgs ["--cap-add", "SYS_ADMIN"] `shouldBe`
        Left (DeniedFlag "--cap-add")

    it "rejects [\"--verbose\", \"--privileged\", \"--debug\"]" $ do
      case checkContainerArgs ["--verbose", "--privileged", "--debug"] of
        Left (DeniedFlag f) -> f `shouldBe` "--privileged"
        Right () -> expectationFailure "expected Left DeniedFlag"

    it "accepts [\"--verbose\", \"--debug\"]" $ do
      checkContainerArgs ["--verbose", "--debug"] `shouldBe` Right ()

    it "accepts empty list" $ do
      checkContainerArgs [] `shouldBe` Right ()

    it "rejects --pid=host" $ do
      checkContainerArgs ["--pid=host"] `shouldBe`
        Left (DeniedFlag "--pid=host")

    it "rejects --network=host" $ do
      checkContainerArgs ["--network=host"] `shouldBe`
        Left (DeniedFlag "--network=host")

    it "rejects --userns=host" $ do
      checkContainerArgs ["--userns=host"] `shouldBe`
        Left (DeniedFlag "--userns=host")

    it "rejects --uts=host" $ do
      checkContainerArgs ["--uts=host"] `shouldBe`
        Left (DeniedFlag "--uts=host")

    it "rejects --ipc=host" $ do
      checkContainerArgs ["--ipc=host"] `shouldBe`
        Left (DeniedFlag "--ipc=host")

    it "rejects --device" $ do
      checkContainerArgs ["--device", "/dev/sda"] `shouldBe`
        Left (DeniedFlag "--device")

    it "rejects -v (short volume flag)" $ do
      checkContainerArgs ["-v", "/host:/container"] `shouldBe`
        Left (DeniedFlag "-v")

  describe "containerEngineBinary" $ do
    it "Docker -> \"docker\"" $ do
      containerEngineBinary Docker `shouldBe` "docker"

    it "Podman -> \"podman\"" $ do
      containerEngineBinary Podman `shouldBe` "podman"

    it "Kubectl -> \"kubectl\"" $ do
      containerEngineBinary Kubectl `shouldBe` "kubectl"

  describe "flavourToBinary" $ do
    it "HClaudeCode -> \"claude\"" $ do
      flavourToBinary HClaudeCode `shouldBe` "claude"

    it "HCodex -> \"codex\"" $ do
      flavourToBinary HCodex `shouldBe` "codex"

    it "HOpenCode -> \"opencode\"" $ do
      flavourToBinary HOpenCode `shouldBe` "opencode"

    it "HHermes -> \"hermes\"" $ do
      flavourToBinary HHermes `shouldBe` "hermes"

    it "HPureClaw -> \"pureclaw\"" $ do
      flavourToBinary HPureClaw `shouldBe` "pureclaw"

    it "HCustom \"my-tool\" -> \"my-tool\"" $ do
      flavourToBinary (HCustom "my-tool") `shouldBe` "my-tool"

  describe "buildContainerExecArgv" $ do
    it "produces correct Docker argv structure with -- separator" $ do
      let tgt = unsafeTarget "my-container"
          cs  = ContainerSpec { _cs_engine = Docker, _cs_target = tgt }
          argv = buildContainerExecArgv cs HClaudeCode ["--verbose"]
      argv `shouldBe`
        ["docker", "exec", "-it", "my-container", "--", "claude", "--verbose"]

    it "produces correct Podman argv" $ do
      let tgt = unsafeTarget "pod1"
          cs  = ContainerSpec { _cs_engine = Podman, _cs_target = tgt }
          argv = buildContainerExecArgv cs HCodex []
      argv `shouldBe` ["podman", "exec", "-it", "pod1", "--", "codex"]

    it "produces correct Kubectl argv with pod/name:container target" $ do
      let tgt = unsafeTarget "my-pod"
          cs  = ContainerSpec { _cs_engine = Kubectl, _cs_target = tgt }
          argv = buildContainerExecArgv cs HHermes ["--debug", "--foo"]
      argv `shouldBe`
        ["kubectl", "exec", "-it", "my-pod", "--", "hermes", "--debug", "--foo"]

    it "always includes -- separator between target and harness binary" $ do
      let tgt = unsafeTarget "c"
          cs  = ContainerSpec { _cs_engine = Docker, _cs_target = tgt }
          argv = buildContainerExecArgv cs HClaudeCode []
      -- The "--" must appear AFTER the target and BEFORE the binary.
      -- Position is 4 (0-indexed: docker=0, exec=1, -it=2, target=3, --=4)
      argv `shouldSatisfy` \xs -> case drop 4 xs of
        ("--" : _) -> True
        _          -> False

    it "harness args appear after the binary name" $ do
      let tgt = unsafeTarget "web"
          cs  = ContainerSpec { _cs_engine = Podman, _cs_target = tgt }
          argv = buildContainerExecArgv cs HPureClaw ["--depth", "1"]
      argv `shouldBe`
        ["podman", "exec", "-it", "web", "--", "pureclaw", "--depth", "1"]

  describe "validateCwd" $ do
    it "rejects path containing .." $ do
      case validateCwd (Just "../../etc") of
        Left CwdPathTraversal -> pure ()
        other -> expectationFailure
          ("expected Left CwdPathTraversal; got " <> show other)

    it "rejects path with internal .. component" $ do
      case validateCwd (Just "/tmp/foo/../../etc/passwd") of
        Left CwdPathTraversal -> pure ()
        other -> expectationFailure
          ("expected Left CwdPathTraversal; got " <> show other)

    it "accepts Nothing (no cwd)" $ do
      validateCwd Nothing `shouldBe` Right Nothing

    it "accepts plain absolute path" $ do
      case validateCwd (Just "/tmp/safe") of
        Right (Just p) -> T.pack p `shouldBe` "/tmp/safe"
        other -> expectationFailure
          ("expected Right (Just \"/tmp/safe\"); got " <> show other)

    it "accepts plain relative path" $ do
      case validateCwd (Just "workdir") of
        Right (Just p) -> T.pack p `shouldBe` "workdir"
        other -> expectationFailure
          ("expected Right (Just \"workdir\"); got " <> show other)

    it "rejects path that is just .." $ do
      case validateCwd (Just "..") of
        Left CwdPathTraversal -> pure ()
        other -> expectationFailure
          ("expected Left CwdPathTraversal; got " <> show other)
