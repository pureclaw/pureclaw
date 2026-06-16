# Web Frontend Slash-Command Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route the web frontend's `handleSend` through the same pre-inference slash-command classification + short-circuit the TUI/channels use, so `/`-commands never silently reach the LLM, with full command parity and a default-localhost trust boundary.

**Architecture:** A transport-agnostic seam `PureClaw.Agent.SlashDispatch.runSlashInput` reuses the existing `parseInput` (classification) and `executeSlashCommand` (execution) against a buffering "capture" `ChannelHandle`. `handleSend` calls it first; only non-slash input proceeds to `doCompletion`/the harness. The web server binds `127.0.0.1` by default with an opt-in configurable interface. Slash output is transient (not persisted) and tagged with an explicit `kind` field in the response.

**Tech Stack:** Haskell (GHC 9.12.1, GHC2021), WAI/Warp, optparse-applicative, hspec; React/TypeScript frontend. Nix flake — all cabal commands are prefixed `nix develop . --command`.

**Spec:** `docs/superpowers/specs/2026-06-15-web-frontend-slash-dispatch-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/PureClaw/Handles/Channel.hs` | `InteractiveUnsupported` exception + `mkCaptureChannelHandle` | Modify |
| `src/PureClaw/Agent/SlashDispatch.hs` | `SlashResult`, pure `classifyInput`, IO `runSlashInput` | Create |
| `src/PureClaw/Frontend/Server.hs` | `_fsc_bindHost` config, `setHost`, CORS follows host, non-loopback WARN | Modify |
| `src/PureClaw/Frontend/API.hs` | `_fe_agentEnv` field; `handleSend` short-circuit; `kind` envelope | Modify |
| `src/PureClaw/CLI/Commands.hs` | `--bind` flag → config; populate `_fe_agentEnv` | Modify |
| `frontend/src/useApi.ts`, `frontend/src/App.tsx` | Read body; `kind`-keyed transient bubble | Modify |
| `test/Agent/SlashDispatchSpec.hs` | Unit tests for classify + run | Create |
| `test/Handles/ChannelSpec.hs` (or existing) | Capture channel unit tests | Create/Modify |
| `test/Frontend/ServerSpec.hs` (or existing) | Bind-host + CORS tests | Create/Modify |
| `test/Integration/CLISpec.hs` | End-to-end slash short-circuit tests | Modify |
| `test/Support/AgentEnv.hs` | Shared `mkTestAgentEnv` helper | Create |
| `test/Frontend/APISpec.hs`, `StreamHarness.hs`, `ActivityProbeSpec.hs` | Add `_fe_agentEnv` to `FrontendEnv` literals | Modify |
| `pureclaw.cabal` | Register new modules in library + test suite | Modify |

**Build/test commands (use throughout):**
- Build: `nix develop . --command cabal build`
- Test (one module): `nix develop . --command cabal test --test-options="--match \"<pattern>\""`
- Full test: `nix develop . --command cabal test`
- Stale build fix: `nix develop . --command bash -c "cabal clean && cabal build"`

---

## Task 1: Capture channel + `InteractiveUnsupported`

**Files:**
- Modify: `src/PureClaw/Handles/Channel.hs`
- Test: `test/Handles/ChannelSpec.hs` (create; register in `pureclaw.cabal` test suite `other-modules`)

- [ ] **Step 1: Write the failing test**

Create `test/Handles/ChannelSpec.hs`:

```haskell
module Handles.ChannelSpec (spec) where

import Control.Exception (try, evaluate)
import Test.Hspec

import PureClaw.Core.Errors (PublicError (..))
import PureClaw.Handles.Channel

spec :: Spec
spec = describe "mkCaptureChannelHandle" $ do
  it "buffers multiple _ch_send messages joined by newline" $ do
    (h, readOut) <- mkCaptureChannelHandle
    _ch_send h (OutgoingMessage "first")
    _ch_send h (OutgoingMessage "second")
    out <- readOut
    out `shouldBe` "first\nsecond"

  it "captures _ch_sendError and _ch_sendChunk output too" $ do
    (h, readOut) <- mkCaptureChannelHandle
    _ch_send h (OutgoingMessage "ok")
    _ch_sendError h (TemporaryError "boom")
    _ch_sendChunk h (ChunkText "chunk")
    out <- readOut
    out `shouldBe` "ok\nboom\nchunk"

  it "is non-streaming" $ do
    (h, _) <- mkCaptureChannelHandle
    _ch_streaming h `shouldBe` False

  it "throws InteractiveUnsupported on prompt" $ do
    (h, _) <- mkCaptureChannelHandle
    r <- try (_ch_prompt h "API key: ") :: IO (Either InteractiveUnsupported Text)
    case r of
      Left (InteractiveUnsupported label) -> label `shouldBe` "API key: "
      Right _ -> expectationFailure "expected InteractiveUnsupported"

  it "throws InteractiveUnsupported on promptSecret and readSecret" $ do
    (h, _) <- mkCaptureChannelHandle
    r1 <- try (_ch_promptSecret h "pw") :: IO (Either InteractiveUnsupported Text)
    r2 <- try (_ch_readSecret h)        :: IO (Either InteractiveUnsupported Text)
    (isLeft r1, isLeft r2) `shouldBe` (True, True)

  it "throws on _ch_receive" $ do
    (h, _) <- mkCaptureChannelHandle
    r <- try (_ch_receive h) :: IO (Either InteractiveUnsupported IncomingMessage)
    isLeft r `shouldBe` True
  where
    isLeft = either (const True) (const False)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop . --command cabal test --test-options="--match \"mkCaptureChannelHandle\""`
Expected: FAIL — `mkCaptureChannelHandle` / `InteractiveUnsupported` not in scope.

- [ ] **Step 3: Implement in `Handles/Channel.hs`**

Add to the export list (after `mkNoOpChannelHandle`):

```haskell
  , mkCaptureChannelHandle
  , InteractiveUnsupported (..)
  , renderPublicError
```

Add imports at the top (qualified style per coding standards):

```haskell
import Control.Exception (Exception, throwIO)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Text qualified as T
```

Add the implementation at the end of the module:

```haskell
-- | Thrown when a slash command tries to read interactive input through a
-- capture channel (which has no interactive transport). Carries the prompt
-- label so the caller can report which command needs the CLI.
newtype InteractiveUnsupported = InteractiveUnsupported Text
  deriving stock (Show, Eq)

instance Exception InteractiveUnsupported

-- | Render a 'PublicError' to channel-safe display text (for buffering).
renderPublicError :: PublicError -> Text
renderPublicError (TemporaryError t) = t
renderPublicError RateLimitError     = "Rate limit reached."
renderPublicError NotAllowedError    = "Not authorized."

-- | A channel handle that buffers all output instead of writing to a
-- transport, and refuses interactive input. Used by the slash-dispatch seam
-- to capture a command's output as text. Returns the handle plus a reader
-- that yields the accumulated output (messages joined by newline).
mkCaptureChannelHandle :: IO (ChannelHandle, IO Text)
mkCaptureChannelHandle = do
  buf <- newIORef []  -- reversed list of emitted fragments
  let append t = modifyIORef' buf (t :)
      handle = ChannelHandle
        { _ch_receive      = throwIO (InteractiveUnsupported "(receive)")
        , _ch_send         = \(OutgoingMessage t) -> append t
        , _ch_sendError    = append . renderPublicError
        , _ch_sendChunk    = \c -> case c of
            ChunkText t -> append t
            ChunkDone   -> pure ()
        , _ch_streaming    = False
        , _ch_readSecret   = throwIO (InteractiveUnsupported "(secret)")
        , _ch_prompt       = throwIO . InteractiveUnsupported
        , _ch_promptSecret = throwIO . InteractiveUnsupported
        }
      reader = T.intercalate "\n" . reverse <$> readIORef buf
  pure (handle, reader)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nix develop . --command cabal test --test-options="--match \"mkCaptureChannelHandle\""`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Handles/Channel.hs test/Handles/ChannelSpec.hs pureclaw.cabal
git commit -m "feat(channel): capture ChannelHandle + InteractiveUnsupported for slash dispatch"
```

---

## Task 2: Pure classification (`SlashDispatch` part 1)

**Files:**
- Create: `src/PureClaw/Agent/SlashDispatch.hs` (register in `pureclaw.cabal` library `exposed-modules`)
- Test: `test/Agent/SlashDispatchSpec.hs` (register in test `other-modules`)

The pure half: classify raw input and render the fixed short-circuit messages. No IO, so 100% unit-testable across every `parseInput` variant.

- [ ] **Step 1: Write the failing test**

Create `test/Agent/SlashDispatchSpec.hs`:

```haskell
module Agent.SlashDispatchSpec (spec) where

import Test.Hspec

import PureClaw.Agent.SlashCommands (SlashCommand (..))
import PureClaw.Agent.SlashDispatch
import PureClaw.Routing.Config (defaultRoutingConfig)

spec :: Spec
spec = describe "classifyInput" $ do
  let rc = defaultRoutingConfig

  it "passes ordinary chat through" $
    classifyInput rc "write a function" `shouldBe` ClassPass "write a function"

  it "classifies a known command" $
    classifyInput rc "/help" `shouldBe` ClassCommand CmdHelp

  it "short-circuits bare /N (Switch) with a message, not a command" $
    case classifyInput rc "/0" of
      ClassMessage m -> m `shouldSatisfy` (not . null . show)
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "short-circuits Inject (/N payload) with a message" $
    case classifyInput rc "/3 run tests" of
      ClassMessage _ -> pure ()
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "renders an unknown command as a friendly message" $
    case classifyInput rc "/foo" of
      ClassMessage m -> m `shouldContain` "/foo"
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "renders an invalid /tab resume id distinctly" $
    case classifyInput rc "/tab resume not a valid id!!" of
      ClassMessage m -> m `shouldContain` "session id"
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)
```

> Note: confirm the exact exported name of the default `RoutingConfig` value (`grep -n "defaultRoutingConfig\|_rc_maxTabs" src/PureClaw/Routing/Config.hs`). If it requires construction, build a minimal `RoutingConfig` in the test instead. Confirm `SlashCommand`'s `Eq`/`Show` instances exist (`grep -n "deriving.*Eq\|deriving.*Show" src/PureClaw/Agent/SlashCommands.hs` near `data SlashCommand`); if `CmdHelp` isn't `Eq`-comparable, assert via a `case` match instead of `shouldBe`.

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop . --command cabal test --test-options="--match \"classifyInput\""`
Expected: FAIL — module `PureClaw.Agent.SlashDispatch` does not exist.

- [ ] **Step 3: Implement the pure half of `SlashDispatch.hs`**

```haskell
module PureClaw.Agent.SlashDispatch
  ( SlashResult (..)
  , SlashClass (..)
  , classifyInput
  , runSlashInput        -- implemented in Task 3
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.SlashCommands (SlashCommand)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT

-- | Outcome the transport acts on. 'SlashHandled' must NOT reach inference.
data SlashResult
  = SlashHandled !Text      -- ^ short-circuit; this is the user-facing output
  | SlashPassThrough !Text  -- ^ ordinary chat; caller proceeds to inference
  deriving stock (Show, Eq)

-- | Pure classification of raw input. Only 'ClassCommand' requires IO
-- (a scoped env + capture channel) to execute; the others are decided here.
data SlashClass
  = ClassPass !Text            -- ^ Default: passthrough to inference
  | ClassMessage !Text         -- ^ Switch/Inject/ParseError: short-circuit text
  | ClassCommand !SlashCommand -- ^ a recognized command to execute
  deriving stock (Show, Eq)

-- | Classify input using the SAME parser the TUI/channels use, so behavior
-- is identical. Positional routing forms (Switch/Inject) and parse errors
-- become a fixed short-circuit 'ClassMessage' (never inference); only a
-- recognized command is handed on as 'ClassCommand'.
classifyInput :: RT.RoutingConfig -> Text -> SlashClass
classifyInput rc raw =
  case Parse.parseInput rc raw of
    Right (RT.Default t)        -> ClassPass t
    Right (RT.ParsedSlashCmd c) -> ClassCommand c
    Right (RT.Switch _)         -> ClassMessage switchMsg
    Right (RT.Inject _ _)       -> ClassMessage injectMsg
    Left err                    -> ClassMessage (renderParseError raw err)
  where
    switchMsg = "Tab switching isn't typed as /N in the web client — use the tab controls."
    injectMsg = "Cross-tab send isn't available from the web client yet."

-- | User-friendly rendering of a routing 'ParseError' for a browser bubble.
renderParseError :: Text -> RT.ParseError -> Text
renderParseError raw err = case err of
  RT.ParseErrorInvalidSessionId -> "That doesn't look like a valid session id. Try /tabs to list."
  RT.ParseErrorEmptyInput       -> "Empty command. Try /help."
  RT.ParseErrorIndexOutOfRange n ->
    "Tab " <> T.pack (show n) <> " doesn't exist. Try /tabs to list."
  _ -> "Unknown command: " <> firstWord <> ". Try /help."
  where
    -- the typed command token, e.g. "/foo" from "/foo bar"
    firstWord = T.takeWhile (/= ' ') (T.stripStart raw)
```

> The `renderParseError` `_` arm must cover every remaining `ParseError` constructor — check `grep -n "ParseError" src/PureClaw/Routing/Types.hs` and confirm the catch-all is acceptable (it is: any unmatched code maps to "Unknown command"). The `/foo` test asserts the message includes the typed token.

- [ ] **Step 4: Run test to verify it passes**

Run: `nix develop . --command cabal test --test-options="--match \"classifyInput\""`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Agent/SlashDispatch.hs test/Agent/SlashDispatchSpec.hs pureclaw.cabal
git commit -m "feat(slash-dispatch): pure classifyInput over the shared routing parser"
```

---

## Task 3: `runSlashInput` IO seam (`SlashDispatch` part 2)

**Files:**
- Modify: `src/PureClaw/Agent/SlashDispatch.hs`
- Test: `test/Agent/SlashDispatchSpec.hs`

`runSlashInput` runs a command against a lazily-built scoped env + capture channel, returning the captured output, and converts an `InteractiveUnsupported` throw into a deferral message that still includes any buffered output.

- [ ] **Step 1: Write the failing test**

Add to `test/Agent/SlashDispatchSpec.hs` (extend imports as needed). Use a scoped-env builder backed by a capture channel over a minimal test `AgentEnv` from the shared helper (Task 6 creates `mkTestAgentEnv`; this task may be implemented after Task 6, or use a locally-constructed env). The behaviors to pin:

```haskell
  describe "runSlashInput" $ do
    it "passes ordinary chat through without building a scoped env" $ do
      env <- mkTestAgentEnv
      let mkScoped = error "must not be called for passthrough"
      res <- runSlashInput env mkScoped "hello there"
      res `shouldBe` SlashPassThrough "hello there"

    it "returns the captured output of a command" $ do
      env <- mkTestAgentEnv
      res <- runSlashInput env (scopedCapture env) "/help"
      case res of
        SlashHandled out -> out `shouldContain` "/help"   -- help text mentions commands
        _ -> expectationFailure "expected SlashHandled"

    it "converts InteractiveUnsupported into a deferral incl. buffered output" $ do
      env <- mkTestAgentEnv
      -- /provider add prompts -> InteractiveUnsupported
      res <- runSlashInput env (scopedCapture env) "/provider add anthropic"
      case res of
        SlashHandled out -> do
          out `shouldContain` "interactive"
          out `shouldContain` issueUrlMarker   -- the tracking link
        _ -> expectationFailure "expected SlashHandled deferral"
```

where `scopedCapture env` is a test helper:

```haskell
scopedCapture :: AgentEnv -> IO (AgentEnv, IO Text)
scopedCapture base = do
  (h, readOut) <- mkCaptureChannelHandle
  pure (base { _env_channel = h }, readOut)
```

> `mkTestAgentEnv` comes from `Test.Support.AgentEnv` (Task 6). If implementing Task 3 before Task 6, inline a minimal `AgentEnv` here and refactor later. `issueUrlMarker` is a substring of the embedded tracking URL — keep it in one place (see Step 3).

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop . --command cabal test --test-options="--match \"runSlashInput\""`
Expected: FAIL — `runSlashInput` not implemented.

- [ ] **Step 3: Implement `runSlashInput`**

Add imports:

```haskell
import Control.Exception (try)
import PureClaw.Agent.Env (AgentEnv (..), envTranscript)
import PureClaw.Agent.SlashCommands (SlashCommand (..), executeSlashCommand)
import PureClaw.Core.Types (emptyContext, addMessage)  -- confirm exact module/exports
import PureClaw.Handles.Channel (InteractiveUnsupported (..))
import PureClaw.Session.Handle (loadRecentMessages)
```

```haskell
-- | Tracking issue for interactive-command support in the web UI. Embedded
-- in the deferral message. MUST be the real issue URL before merge (Task 9).
interactiveIssueUrl :: Text
interactiveIssueUrl = "https://github.com/<owner>/<repo>/issues/<n>"

-- | Execute one line of user input against a lazily-built scoped env.
--
-- @mkScoped@ builds (scoped env, output reader): the env's '_env_channel'
-- is a capture channel and '_env_session' a FRESH ref over the target
-- session. It is invoked ONLY for a recognized command, so passthrough chat
-- and the harness path pay no scoping cost.
runSlashInput
  :: AgentEnv                      -- ^ base shared env (for routing config)
  -> IO (AgentEnv, IO Text)        -- ^ lazy scoped-env + output-reader builder
  -> Text                          -- ^ raw user input
  -> IO SlashResult
runSlashInput base mkScoped raw =
  case classifyInput (_env_routingConfig base) raw of
    ClassPass t      -> pure (SlashPassThrough t)
    ClassMessage t   -> pure (SlashHandled t)
    ClassCommand cmd -> do
      (scoped, readOut) <- mkScoped
      ctx <- buildContext scoped
      outcome <- try (executeSlashCommand scoped cmd ctx)
      case outcome of
        Right _ -> SlashHandled <$> readOut
        Left (InteractiveUnsupported _) -> do
          buffered <- readOut
          pure (SlashHandled (deferralMessage cmd buffered))

-- | Build a Context from the scoped session's transcript so read-only
-- commands (e.g. /status) report accurate counts. The returned Context from
-- the command is discarded (output is transient).
buildContext :: AgentEnv -> IO _   -- ^ Context (use the concrete type)
buildContext env = do
  tx <- envTranscript env
  history <- loadRecentMessages tx 50 100000
  pure (foldl (flip addMessage) (emptyContext Nothing) history)

deferralMessage :: SlashCommand -> Text -> Text
deferralMessage _cmd buffered =
  let note = "This command needs interactive input, which the web UI doesn't \
             \support yet (tracking: " <> interactiveIssueUrl <> "). Use the CLI for now."
  in if T.null buffered then note else buffered <> "\n" <> note
```

> Replace the `_` in `buildContext :: AgentEnv -> IO _` with the concrete `Context` type and fix the import (`grep -n "emptyContext ::\|addMessage ::\|type Context\|data Context" src/PureClaw/Core/Types.hs`). Mirror `doCompletion` (`API.hs:2274`) which does `foldl (flip addMessage) (emptyContext systemPrompt) history`. Keep `issueUrlMarker` in the test as a substring of `interactiveIssueUrl` (e.g. `"/issues/"`).

- [ ] **Step 4: Run test to verify it passes**

Run: `nix develop . --command cabal test --test-options="--match \"runSlashInput\""`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Agent/SlashDispatch.hs test/Agent/SlashDispatchSpec.hs
git commit -m "feat(slash-dispatch): runSlashInput seam with capture + interactive deferral"
```

---

## Task 4: Default-localhost bind + CORS + fail-loud

**Files:**
- Modify: `src/PureClaw/Frontend/Server.hs`
- Test: `test/Frontend/ServerSpec.hs` (create or extend; register in cabal)

- [ ] **Step 1: Write the failing test**

```haskell
module Frontend.ServerSpec (spec) where

import Test.Hspec
import PureClaw.Frontend.Server

spec :: Spec
spec = describe "frontend bind host" $ do
  it "defaults to loopback" $
    _fsc_bindHost defaultFrontendConfig `shouldBe` "127.0.0.1"

  it "classifies loopback hosts" $ do
    isLoopbackHost "127.0.0.1" `shouldBe` True
    isLoopbackHost "localhost" `shouldBe` True
    isLoopbackHost "::1"       `shouldBe` True

  it "flags non-loopback hosts (drives the startup WARN)" $ do
    isLoopbackHost "0.0.0.0"     `shouldBe` False
    isLoopbackHost "192.168.1.5" `shouldBe` False

  it "CORS origin follows the configured bind host + port" $
    corsAllowedOrigin (defaultFrontendConfig { _fsc_bindHost = "192.168.1.5", _fsc_port = 9000 })
      `shouldBe` "http://192.168.1.5:9000"
```

> Export `isLoopbackHost` and `corsAllowedOrigin` from `Server.hs` for testability. Confirm current default port is `8080` so the default-origin case stays `http://localhost:8080` if you also keep a localhost alias.

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop . --command cabal test --test-options="--match \"frontend bind host\""`
Expected: FAIL — `_fsc_bindHost` / `isLoopbackHost` / `corsAllowedOrigin` undefined.

- [ ] **Step 3: Implement**

In `FrontendConfig` add the field and default:

```haskell
data FrontendConfig = FrontendConfig
  { _fsc_port          :: Int
  , _fsc_bindHost      :: String       -- NEW: Warp HostPreference string; default loopback
  , _fsc_staticDir     :: FilePath
  , _fc_allowedOrigins :: [Text]
  }

defaultFrontendConfig :: FrontendConfig
defaultFrontendConfig = FrontendConfig
  { _fsc_port          = 8080
  , _fsc_bindHost      = "127.0.0.1"   -- NEW
  , _fsc_staticDir     = "frontend/dist"
  , _fc_allowedOrigins = [ "http://localhost:8080", "http://127.0.0.1:8080" ]
  }
```

Add `import Data.String (fromString)` and update `mkFrontendSettings` to bind the host:

```haskell
mkFrontendSettings :: FrontendConfig -> Warp.Settings
mkFrontendSettings cfg =
  Warp.setPort (_fsc_port cfg)
    $ Warp.setHost (fromString (_fsc_bindHost cfg))   -- NEW
    $ Warp.setTimeout 30
      Warp.defaultSettings
```

Add the loopback predicate and CORS-origin helper, and make `corsMiddleware` use the latter:

```haskell
isLoopbackHost :: String -> Bool
isLoopbackHost h = h `elem` ["127.0.0.1", "localhost", "::1", "[::1]"]

corsAllowedOrigin :: FrontendConfig -> Text
corsAllowedOrigin cfg =
  "http://" <> T.pack (_fsc_bindHost cfg) <> ":" <> T.pack (show (_fsc_port cfg))
```

In `corsMiddleware`, replace the hard-coded `origin` with `encodeUtf8 (corsAllowedOrigin cfg)` (add `import Data.Text.Encoding (encodeUtf8)`; keep `Text.intercalate`/`<>` types consistent). In `runFrontend`'s startup logging (around `Server.hs:111`), emit a WARN when non-loopback:

```haskell
  if isLoopbackHost (_fsc_bindHost cfg)
    then pure ()
    else _lh_logError logger $
      "WARNING: web frontend bound to non-loopback host " <> T.pack (_fsc_bindHost cfg)
        <> " — the FULL slash-command surface (including local code execution via "
        <> "/mcp connect) is reachable by anything that can reach this address. "
        <> "Use only on trusted networks."
```

> Confirm the logger field/function name for stderr-level output (`grep -n "_lh_logError\|logError\|_lh_" src/PureClaw/Handles/Log.hs`). Confirm `Warp.setHost` is exported by the Warp version in use (`grep -rn "setHost" ~/.cabal 2>/dev/null` or check Warp docs); it takes a `HostPreference` which has an `IsString` instance, hence `fromString`.

- [ ] **Step 4: Run test + full build**

Run: `nix develop . --command cabal test --test-options="--match \"frontend bind host\""`
Expected: PASS. Then `nix develop . --command cabal build` (the `-Wincomplete-record-updates`/missing-field check forces every `FrontendConfig` literal to include `_fsc_bindHost` — fix any that fail to compile by adding `, _fsc_bindHost = "127.0.0.1"`).

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Frontend/Server.hs test/Frontend/ServerSpec.hs
git commit -m "feat(frontend): default-localhost bind, CORS follows host, non-loopback WARN"
```

---

## Task 5: `--bind` CLI flag

**Files:**
- Modify: `src/PureClaw/CLI/Commands.hs`
- Test: `test/Integration/CLISpec.hs` (assert `--help` lists `--bind` and its danger note)

- [ ] **Step 1: Write the failing test**

Add to `test/Integration/CLISpec.hs` (follow the existing subprocess pattern in that file):

```haskell
  it "documents the --bind flag with a trust warning" $ do
    (_code, out, _err) <- runPureclaw ["--help"]
    out `shouldContain` "--bind"
    out `shouldContain` "trusted networks"
```

> Use the file's existing helper for spawning the binary (`grep -n "runPureclaw\|readProcess\|System.Process" test/Integration/CLISpec.hs`); match its tuple shape.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command cabal test --test-options="--match \"--bind flag\""`
Expected: FAIL — flag absent from `--help`.

- [ ] **Step 3: Implement**

Add a field to the CLI `Options` record (near the other `strOption`s at `Commands.hs:175-246`) and its parser:

```haskell
  <*> optional (strOption
      ( long "bind"
     <> metavar "HOST"
     <> help "Interface for the web frontend to bind (default 127.0.0.1). \
             \Setting a non-loopback host (e.g. 0.0.0.0) exposes the FULL \
             \slash-command surface, including local code execution via \
             \/mcp connect, to anything that can reach that address — use \
             \only on trusted networks." ))
```

Thread it into the config at the `runFrontend` call (`Commands.hs:934`):

```haskell
          let feCfg = defaultFrontendConfig
                        { _fsc_bindHost = fromMaybe (_fsc_bindHost defaultFrontendConfig) optBind }
          (runFrontend feCfg (Just frontendEnv) logger) $ \_serverAsync ->
```

where `optBind` is the new `Options` field. Add `import Data.String (fromString)` only if needed; `fromMaybe` is already available.

- [ ] **Step 4: Run test + build**

Run: `nix develop . --command cabal build` then `nix develop . --command cabal test --test-options="--match \"--bind flag\""`
Expected: build OK (the new `Options` field must be added to the record's construction/destructuring — `-Werror` will flag misses), test PASS.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/CLI/Commands.hs test/Integration/CLISpec.hs
git commit -m "feat(cli): --bind flag to choose web frontend interface (default localhost)"
```

---

## Task 6: `_fe_agentEnv` field + shared `mkTestAgentEnv`

**Files:**
- Modify: `src/PureClaw/Frontend/API.hs` (add field), `src/PureClaw/CLI/Commands.hs` (populate)
- Create: `test/Support/AgentEnv.hs` (shared `mkTestAgentEnv`)
- Modify: `test/Frontend/APISpec.hs`, `test/Frontend/StreamHarness.hs`, `test/Frontend/ActivityProbeSpec.hs`

- [ ] **Step 1: Write the failing test (compile-level)**

Create `test/Support/AgentEnv.hs` exporting `mkTestAgentEnv :: IO AgentEnv`. Build it by mirroring an existing inline `AgentEnv {…}` literal — copy the most complete one from `test/Agent/SlashCommandsSpec.hs` (`grep -n "AgentEnv$\|AgentEnv {\|= AgentEnv" test/Agent/SlashCommandsSpec.hs`) into this helper, parameterizing nothing (sane defaults: no-op channel, `newIORef Nothing` provider/model/vault, empty registries, `defaultRoutingConfig`, `newTabSubsystem` for the tab fields). Add a trivial test that forces it:

```haskell
module Support.AgentEnvSpec (spec) where
import Test.Hspec
import Test.Support.AgentEnv (mkTestAgentEnv)
import PureClaw.Agent.Env (AgentEnv (..))
import Data.IORef (readIORef)

spec :: Spec
spec = it "builds a usable test AgentEnv" $ do
  env <- mkTestAgentEnv
  readIORef (_env_provider env) >>= (`shouldBe` Nothing)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command cabal build` (test target)
Expected: FAIL — `Test.Support.AgentEnv` missing / `_fe_agentEnv` not yet a field.

- [ ] **Step 3: Implement**

In `API.hs`, add to `FrontendEnv` (after `_fe_maxToolIterations`, keep it LAZY — no bang):

```haskell
  , _fe_agentEnv :: AgentEnv
    -- ^ Shared base env; '_env_channel'/'_env_session' are overridden
    -- per request by the slash-dispatch caller. Lazy back-edge (mirrors the
    -- existing _env_onTabsChanged/_env_startHarness thunks).
```

Add `import PureClaw.Agent.Env (AgentEnv (..))` to `API.hs` if not present (verify no cycle: `Agent.Env` does not import `Frontend.API`).

In `Commands.hs:804`, add `, _fe_agentEnv = env` to the `FrontendEnv { … }` literal (`env` is in scope from `:709`).

Add `_fe_agentEnv = <someAgentEnv>` to the **three** test `FrontendEnv` literals — use `mkTestAgentEnv` (these helpers become `IO`, or take the env as a parameter; thread accordingly):
- `test/Frontend/APISpec.hs:3391`
- `test/Frontend/StreamHarness.hs:87`
- `test/Frontend/ActivityProbeSpec.hs:132`

Register `Test.Support.AgentEnv` and `Support.AgentEnvSpec` in `pureclaw.cabal` test `other-modules`.

- [ ] **Step 4: Run build + full test**

Run: `nix develop . --command cabal build` then `nix develop . --command cabal test`
Expected: builds clean (all 4 `FrontendEnv` sites satisfied), existing suite green.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Frontend/API.hs src/PureClaw/CLI/Commands.hs test/Support/AgentEnv.hs test/Frontend/APISpec.hs test/Frontend/StreamHarness.hs test/Frontend/ActivityProbeSpec.hs pureclaw.cabal
git commit -m "feat(frontend): carry base AgentEnv in FrontendEnv; add shared mkTestAgentEnv"
```

---

## Task 7: `handleSend` short-circuit + `kind` envelope

**Files:**
- Modify: `src/PureClaw/Frontend/API.hs`
- Test: `test/Integration/CLISpec.hs` (end-to-end) and/or `test/Frontend/APISpec.hs`

- [ ] **Step 1: Write the failing tests**

Add integration tests using APISpec's existing helpers: `mkTestFrontendEnvWithTabsAndDir [] tmpDir` (builds a `FrontendEnv`; now also supplies `_fe_agentEnv` via `mkTestAgentEnv`) and `postJSON env path body :: IO (Status, LByteString)`. A session is created on disk first (reuse the spec's session-creation helper — `grep -n "createSession\|writeSessionMeta\|mkSession\b\|sessionDir" test/Frontend/APISpec.hs` — or `postJSON env ["api","tabs","new"] providerNewTabBody` and read back the new sid). The send path is `["api","sessions", sid, "send"]`.

Concrete first test (pattern the rest on it):

```haskell
  describe "handleSend slash short-circuit" $ do
    it "runs /help, returns kind=slash, and does NOT call the provider" $
      withSystemTempDirectory "slash" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        sid <- createProviderSession env tmpDir   -- helper: returns the new sid
        let providerHit = -- env's provider records if complete is ever called
              providerWasCalled env
        (st, body) <- postJSON env ["api","sessions", sid, "send"]
                        "{\"message\":\"/help\"}"
        st `shouldBe` status200
        let j = decodeObj body
        lookupText "kind" j     `shouldBe` Just "slash"
        (lookupText "response" j >>= \t -> pure (T.isInfixOf "/help" t)) `shouldBe` Just True
        providerHit >>= (`shouldBe` False)
        -- transcript gained no Request/Response entries:
        transcriptLineCount tmpDir sid >>= (`shouldBe` 0)
```

Then pin (each replacing `/help` body + assertions, same shape):

- `/status` with the env's provider set to `Nothing` ⇒ `status200`, `kind:"slash"`, no `503`.
- ordinary chat `"hello"` ⇒ provider IS called, `kind:"assistant"`.
- harness session (create via `harnessNewTabBody`) + `/help` ⇒ `kind:"slash"`, and the harness received NO keystrokes (assert via the test harness handle's recorded input — `grep -n "recordedInput\|sentKeys\|fakeHarness" test/Frontend/*.hs`).
- `/0` and `/foo` ⇒ `status200`, `kind:"slash"`, provider not called; `/foo` response contains `"/foo"`.
- `/tab resume bad!!id` ⇒ response contains `"session id"`.
- `/provider add anthropic` ⇒ `kind:"slash"`, response contains `"interactive"` and `"/issues/"`.
- `/new` ⇒ `kind:"slash"`, response contains `"cleared"`, transcript unchanged (observed-behavior pin).
- two sessions `sidA`/`sidB`: interleaved `/status` posts return each session's own counts (per-request session isolation).

> Helpers to add or locate: `createProviderSession`, `providerWasCalled`, `transcriptLineCount`, `decodeObj`/`lookupText`. Several likely exist in APISpec already (`grep -n "decode\|lookup\|providerCalled\|transcript" test/Frontend/APISpec.hs`); reuse them. For "provider not called", the test `FrontendEnv`'s `_fe_provider` should hold a `SomeProvider` whose `complete` flips an `IORef Bool` (or `throwIO`s) — assert it stayed `False`.

- [ ] **Step 2: Run to verify they fail**

Run: `nix develop . --command cabal test --test-options="--match \"slash short-circuit\""`
Expected: FAIL.

- [ ] **Step 3: Implement the short-circuit in `handleSend`**

In `API.hs`, in `handleSend`, after the body decodes to `SendRequest userText reqModel` (`:1968`) and BEFORE the `mMeta`/harness/provider branch, insert:

```haskell
            Right (SendRequest userText reqModel) -> do
              let base = _fe_agentEnv env
                  mkScoped = do
                    (chan, readOut) <- mkCaptureChannelHandle
                    mMetaS <- tryLoad (_fe_sessionsDir env) (T.unpack sid)
                    sh <- mkSessionHandle (_fe_broker env) (_fe_logger env)
                            (_fe_sessionsDir env)
                            (fromMaybe (error "session vanished") mMetaS)
                    sref <- newIORef sh
                    pure (base { _env_channel = chan, _env_session = sref }, readOut)
              slashRes <- runSlashInput base mkScoped userText
              case slashRes of
                SlashHandled out ->
                  respond $ jsonResponse status200
                    (object ["response" .= out, "kind" .= ("slash" :: Text)])
                SlashPassThrough _ -> do
                  -- existing harness/provider logic, unchanged, but each
                  -- success response now also carries "kind" = "assistant":
                  <existing body of the Right branch>
```

Update the two existing success responses in the pass-through path to include the `kind` field:
- harness path: where `sendToHarness` ultimately responds 200, add `"kind" .= ("assistant" :: Text)`.
- provider path (`:1998-1999`): change to
  `object ["response" .= respText, "kind" .= ("assistant" :: Text)]`.

Add imports to `API.hs`: `PureClaw.Agent.SlashDispatch (SlashResult (..), runSlashInput)`, `PureClaw.Handles.Channel (mkCaptureChannelHandle)`, `PureClaw.Session.Handle (mkSessionHandle)`, `Data.IORef (newIORef)`, and `Data.Maybe (fromMaybe)` if missing.

> The `error "session vanished"` is unreachable in practice: `handleSend` already verified `transcript.jsonl` exists (`:1959`), so meta load succeeds; but to keep HPC clean prefer guarding earlier — if `tryLoad` returns `Nothing`, respond 404 before calling `runSlashInput`. Restructure so `mkScoped` cannot fail: load meta once at the top of the `Right` branch, 404 on `Nothing`, and close over the loaded meta. This removes the partial `error`.

- [ ] **Step 4: Run tests + full build/test**

Run: `nix develop . --command cabal build` then `nix develop . --command cabal test`
Expected: new tests PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Frontend/API.hs test/Frontend/APISpec.hs test/Integration/CLISpec.hs
git commit -m "feat(frontend): short-circuit slash commands in handleSend; add response kind field"
```

---

## Task 8: Frontend rendering (`kind`-keyed transient bubble)

**Files:**
- Modify: `frontend/src/useApi.ts`, `frontend/src/App.tsx`

- [ ] **Step 1: Read the current send path**

Read `frontend/src/useApi.ts` (`useSendMessage`, ~lines 236-257) and `frontend/src/App.tsx` (`handleSend`, the optimistic `pending-*` blocks, and `transcriptToMessages`). Note: `useSendMessage` currently ignores the 200 body.

- [ ] **Step 2: Plumb the response body**

In `useSendMessage`, parse the 200 JSON and return `{ response, kind }` to the caller. Type it as an open enum:

```ts
type SendKind = "slash" | "assistant" | string;  // open: unknown -> assistant fallback
interface SendResult { response: string; kind: SendKind; }
```

- [ ] **Step 3: Render the transient slash bubble**

In `App.tsx`, hold an ordered transient list separate from the transcript-derived memo:

```ts
const [slashBubbles, setSlashBubbles] = useState<{ id: string; text: string }[]>([]);
```

In `handleSend`: when `kind === "slash"`, append `{ id, text: response }` to `slashBubbles` and do NOT engage the `pending-*`/thinking optimistic flow; otherwise use the existing assistant flow (treat unknown `kind` as assistant). Render `slashBubbles` interleaved by send order with a muted "command output — not saved" style. They are component state, so they clear on reload (intended).

- [ ] **Step 4: Verify**

Build the frontend per its existing tooling (`grep -n "\"build\"\|\"test\"\|vite\|jest\|vitest" frontend/package.json`). If a test runner exists, add a test asserting a `kind:"slash"` response renders a command bubble and adds no transcript turn; otherwise verify via the `visual-review` skill / manual run. Run the app (`run` skill) and confirm `/help` shows a command bubble and is not sent to the model.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/useApi.ts frontend/src/App.tsx
git commit -m "feat(frontend-ui): render kind=slash responses as transient command bubbles"
```

---

## Task 9: File the interactive-commands follow-up issue + wire the URL

**Files:**
- Modify: `src/PureClaw/Agent/SlashDispatch.hs` (`interactiveIssueUrl`)

- [ ] **Step 1: Create the GitHub issue**

```bash
gh issue create \
  --title "Web UI: support interactive slash commands (prompt/reply streaming channel)" \
  --body "Follow-up to the web slash-dispatch work. Interactive commands (/provider add, /vault set, Signal register) block mid-execution on _ch_prompt and need a bidirectional channel: background-thread execution, SSE prompt events, a POST /api/sessions/{sid}/prompt-reply uplink that resumes the blocked thread, abandonment cancellation/timeout, and frontend prompt UI. The v1 dispatch seam (runSlashInput) swaps the channel in without changes. The prompt-reply endpoint's auth must be revisited with the trust model (it resumes a privileged command). See docs/superpowers/specs/2026-06-15-web-frontend-slash-dispatch-design.md."
```

- [ ] **Step 2: Wire the real URL**

Replace `interactiveIssueUrl`'s placeholder with the URL `gh` printed. Update the `issueUrlMarker` substring in the test if needed (keep it `"/issues/"` so it stays stable).

- [ ] **Step 3: Run the deferral test**

Run: `nix develop . --command cabal test --test-options="--match \"runSlashInput\""`
Expected: PASS (deferral message now contains the real issue URL).

- [ ] **Step 4: Commit**

```bash
git add src/PureClaw/Agent/SlashDispatch.hs
git commit -m "chore(slash-dispatch): link interactive-commands follow-up issue in deferral message"
```

---

## Task 10: Coverage gate, knowledge capture, PR

- [ ] **Step 1: Full build + lint**

Run: `nix develop . --command bash -c "cabal clean && cabal build"` then `nix develop . --command cabal test`. Run hlint if part of the hooks. Expected: `-Wall -Werror` clean, suite green.

- [ ] **Step 2: Coverage gate**

Run coverage per `.coverage-thresholds.json` (the project's enforcement command — `grep -n "coverage" .githooks/pre-push` for the exact invocation). New pure modules (`SlashDispatch`, capture channel) should be ~100%; ensure no new uncovered branch. `Frontend.API` glue falls under its existing waiver, but the new decision logic must be exercised by Task 7's tests.

- [ ] **Step 3: Knowledge capture (per CLAUDE.md)**

Run `/self-reflect` to capture learnings; commit knowledge-base updates so they land with the code.

- [ ] **Step 4: PR**

```bash
git push -u origin feat/web-frontend-slash-dispatch
gh pr create --title "Unified pre-inference slash-command dispatch for the web frontend" \
  --body "Implements docs/superpowers/specs/2026-06-15-web-frontend-slash-dispatch-design.md. Routes web handleSend through the shared parseInput + executeSlashCommand path via a capture channel; default-localhost bind with opt-in --bind; explicit response kind; full command parity (only /N Switch/Inject drop out); interactive commands deferred (tracking issue linked). 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Open verification items (resolve during implementation, do not block planning)

- Exact `RoutingConfig` default constructor name (`Routing.Config`).
- `SlashCommand` `Eq`/`Show` derivation (affects Task 2 test assertion style).
- Concrete `Context` type + `emptyContext`/`addMessage` module (Task 3 `buildContext`).
- `Warp.setHost` availability + `HostPreference` `IsString` (Task 4).
- Logger stderr function name `_lh_logError` (Task 4).
- Frontend test runner presence (Task 8).
- Exact coverage enforcement command (Task 10).
