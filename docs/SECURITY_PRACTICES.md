# PureClaw Security Practices

This document is mandatory reading for all implementation agents and contributors. Every rule here is backed by a real security failure in a production AI agent runtime. We've done the postmortem so you don't have to repeat it.

The core principle: **make the correct path the only path**. If security requires remembering to call a function, it will eventually be forgotten. Use the type system to make forgetting a compile error.

---

## 1. Cryptography

### 1.1 Never roll your own crypto

Use `crypton` for all cryptographic operations. There are no exceptions.

**Never do this:**
```haskell
-- XOR "encryption" — this is Vigenère, broken since the 1800s
xorCipher :: ByteString -> ByteString -> ByteString
xorCipher key = BS.pack . zipWith xor (cycle (BS.unpack key)) . BS.unpack
```

**Do this:**
```haskell
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (cipherInit, ctrCombine, makeIV)
import Crypto.Error (throwCryptoError)

encryptSecret :: AES256Key -> IV -> ByteString -> ByteString
encryptSecret key iv plaintext =
  let cipher = throwCryptoError (cipherInit key)
  in ctrCombine cipher iv plaintext
```

**Why it matters:** ZeroClaw shipped with a repeating-key XOR cipher for API key storage (issue #1). Broken since the 1800s. It was found on day 1.

### 1.2 Use cryptographic randomness for all security tokens

**Never do this:**
```haskell
-- DefaultHasher / SipHash is for hash tables, not security
import Data.Hashable (hash)
import Data.Time (getCurrentTime)
import System.Posix (getProcessID)

generatePairingCode :: IO Text
generatePairingCode = do
  t <- getCurrentTime
  pid <- getProcessID
  pure $ tshow $ abs (hash (t, pid)) `mod` 1000000
```

**Do this:**
```haskell
import Crypto.Random (getRandomBytes)
import Data.Word (Word32)

generatePairingCode :: IO Text
generatePairingCode = do
  bytes <- getRandomBytes 4
  let n = (fromIntegral (BS.index bytes 0) `shiftL` 24
        .|. fromIntegral (BS.index bytes 1) `shiftL` 16
        .|. fromIntegral (BS.index bytes 2) `shiftL`  8
        .|. fromIntegral (BS.index bytes 3)) :: Word32
  pure $ T.justifyRight 6 '0' $ tshow (n `mod` 1000000)
```

**Why it matters:** ZeroClaw's pairing code was brute-forceable in milliseconds (#2). `SystemTime` + PID is not entropy.

### 1.3 Use constant-time comparison for all secrets

**Never do this:**
```haskell
-- Length branch leaks timing information
verifyToken :: Text -> Text -> Bool
verifyToken expected actual =
  T.length expected == T.length actual && expected == actual
```

**Do this:**
```haskell
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.ByteArray (constEq)

verifyToken :: SecretToken -> SecretToken -> Bool
verifyToken (SecretToken expected) (SecretToken actual) =
  constEq expected actual
```

**Why it matters:** ZeroClaw's `constant_time_eq` returned early on length mismatch, leaking secret length through timing (#57). `constEq` from `memory` pads before comparing.

---

## 2. Secret Management

### 2.1 Secrets must not be showable

Define all secret types with redacted `Show` instances. This prevents accidental logging, error messages, and debug output from leaking credentials.

```haskell
newtype ApiKey = ApiKey ByteString

instance Show ApiKey where
  show _ = "ApiKey <redacted>"

newtype BearerToken = BearerToken ByteString

instance Show BearerToken where
  show _ = "BearerToken <redacted>"

newtype PairingCode = PairingCode Text

instance Show PairingCode where
  show _ = "PairingCode <redacted>"
```

Every struct containing a secret type will automatically redact it in all log output, error messages, and exception traces. You'd have to explicitly unwrap to leak.

**Why it matters:** ZeroClaw leaked API keys in provider error messages (#6) and LLM error responses to WhatsApp users (#59) because request/response structs had full `Debug` implementations.

### 2.2 Separate config from runtime secrets

Never serialize secrets into config files. Define two distinct types:

```haskell
-- Serializable — safe to write to disk
data Config = Config
  { configProvider    :: Provider
  , configModel       :: ModelId
  , configGatewayPort :: Port
  , configWorkspace   :: FilePath
  } deriving (Show, Eq, Generic, ToTOML, FromTOML)

-- Not serializable — secrets come from env/keychain only
data RuntimeConfig = RuntimeConfig
  { runtimeConfig  :: Config
  , runtimeApiKey  :: ApiKey      -- no ToTOML instance
  , runtimePairKey :: PairingKey  -- no ToTOML instance
  }
-- Note: no ToTOML/ToJSON instance on RuntimeConfig
```

Attempting to serialize `RuntimeConfig` to TOML fails to compile. Secrets can only be loaded from environment variables or an encrypted keychain, never written to plaintext config.

**Why it matters:** ZeroClaw's onboarding wrote API keys into `config.toml` in plaintext (#1090). Users then committed them to git.

### 2.3 Never pass secrets as process arguments

Subprocess arguments are visible in `ps`, `/proc/$pid/cmdline`, and system logs.

**Never do this:**
```haskell
-- Token appears in ps output
runTunnel :: TunnelToken -> IO ()
runTunnel (TunnelToken token) =
  callProcess "cloudflared" ["tunnel", "--token", T.unpack token]
```

**Do this:**
```haskell
import System.Process.Typed

runTunnel :: TunnelToken -> IO ()
runTunnel (TunnelToken token) =
  runProcess_ $ proc "cloudflared" ["tunnel", "--token-stdin"]
    & setStdin (byteStringInput (encodeUtf8 token <> "\n"))
```

**Why it matters:** ZeroClaw tunnel tokens were visible in `ps` output (#11).

### 2.4 Subprocesses must not inherit secrets from the environment

**Never do this:**
```haskell
-- Inherits full parent environment — every secret is exposed
runShell :: Text -> IO Text
runShell cmd = do
  out <- readProcess "sh" ["-c", T.unpack cmd] ""
  pure (T.pack out)
```

**Do this:**
```haskell
import System.Process.Typed

runShell :: AllowedEnvVars -> AuthorizedCommand -> IO ProcessResult
runShell (AllowedEnvVars envWhitelist) (AuthorizedCommand cmd args) = do
  let cfg = proc (T.unpack cmd) (map T.unpack args)
              & setEnv (Just envWhitelist)   -- explicit allowlist, not inherited
  runProcess cfg
```

**Why it matters:** ZeroClaw's shell tool inherited the full parent environment, exposing `ANTHROPIC_API_KEY` and all other secrets to every shell command (#53).

---

## 3. Injection Prevention

### 3.1 Shell commands must use argument lists, never strings

The only correct way to run a subprocess is with an explicit argument list. String interpolation into shell commands is banned.

**Never do this:**
```haskell
-- BANNED: string passed to sh -c
runCommand :: Text -> IO ()
runCommand userCmd =
  callProcess "sh" ["-c", T.unpack userCmd]

-- BANNED: any format-string construction of shell commands  
takeScreenshot :: FilePath -> IO ()
takeScreenshot path =
  callProcess "sh" ["-c", "import -window root " <> path]
```

**Do this:**
```haskell
import System.Process.Typed

-- Arguments are a list — metacharacters are never interpreted
takeScreenshot :: SafePath -> IO ()
takeScreenshot (SafePath path) =
  runProcess_ $ proc "import" ["-window", "root", path]
```

The `shell :: String -> ProcessConfig` constructor from `typed-process` exists but is banned in this codebase. If you think you need it, you don't.

**Why it matters:** ZeroClaw's shell tool passed full strings to `sh -c`, and its allowlist only checked the first whitespace-delimited word. `ls; cat ~/.zeroclaw/config.toml` bypassed it (#3). Screenshot filenames were interpolated into shell strings (#601). Git arguments were insufficiently sanitized (#516).

### 3.2 SQL must use parameterized queries

Never construct SQL strings. Use `postgresql-simple` placeholders or `beam` query DSL.

**Never do this:**
```haskell
-- BANNED
fetchMessages :: RowId -> IO [Message]
fetchMessages rowId = do
  let q = "SELECT * FROM messages WHERE rowid > " <> tshow rowId
  execute_ conn (fromString (T.unpack q))
```

**Do this:**
```haskell
import Database.PostgreSQL.Simple

fetchMessages :: Connection -> RowId -> IO [Message]
fetchMessages conn rowId =
  query conn "SELECT * FROM messages WHERE rowid > ? ORDER BY rowid ASC LIMIT 20"
    (Only rowId)
```

`beam` is preferred for complex queries — the SQL never appears as a string at all.

**Why it matters:** ZeroClaw used `format!()` to build SQL and shelled out to `sqlite3` CLI — two mistakes at once (#5, #50). FTS5 queries were also unparameterized (#10).

### 3.3 Structured tool calls only — no free-text JSON extraction

Tool calls must be parsed from provider-structured responses (`tool_use` content blocks, OpenAI function call objects). Never scan raw LLM text output for JSON.

**Never do this:**
```haskell
-- BANNED: scanning free text for JSON enables prompt injection
extractToolCalls :: Text -> [ToolCall]
extractToolCalls llmOutput =
  mapMaybe (decode . encodeUtf8) (findJsonObjects llmOutput)
```

**Do this:**
```haskell
data ContentBlock
  = TextBlock Text
  | ToolUseBlock ToolCallId Text Aeson.Value  -- structured, from provider

parseResponse :: Aeson.Value -> Either ParseError [ContentBlock]
parseResponse = withArray "content" (mapM parseBlock)

-- Tool calls can ONLY come from ToolUseBlock — never from text
executeTools :: [ContentBlock] -> IO [ToolResult]
executeTools blocks = forM [b | ToolUseBlock tid name args <- blocks] $ \(tid, name, args) ->
  dispatchTool tid name args
```

**Why it matters:** ZeroClaw's agent loop scanned raw LLM text for JSON objects. A crafted file content or email body could inject fake tool calls (#355).

---

## 4. Filesystem Safety

### 4.1 All paths must be validated before use — enforced by type

The `SafePath` type is the only path type accepted by file tools. Its constructor is unexported. The only way to obtain a `SafePath` is through `mkSafePath`, which canonicalizes the path and verifies it stays within the workspace.

```haskell
module PureClaw.Security.Path
  ( SafePath          -- type exported, constructor NOT exported
  , mkSafePath
  , PathError(..)
  ) where

newtype SafePath = SafePath FilePath

data PathError
  = PathEscapesWorkspace { requested :: FilePath, resolved :: FilePath }
  | PathIsBlocked        { requested :: FilePath, reason :: Text }
  | PathDoesNotExist     FilePath
  deriving (Show, Eq)

-- Blocked paths — never readable or writable
blockedPaths :: Set FilePath
blockedPaths = Set.fromList
  [ ".zeroclaw/config.toml"
  , ".env", ".env.local", ".env.production"
  , ".ssh", ".gnupg", ".netrc"
  ]

mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) requested = do
  canonical <- canonicalizePath (root </> requested)
  let relative = makeRelative root canonical
  cond
    [ (not (root `isPrefixOf` canonical),
        Left (PathEscapesWorkspace requested canonical))
    , (any (`isPrefixOf` relative) (Set.toList blockedPaths),
        Left (PathIsBlocked requested "blocked path"))
    , otherwise ->
        doesPathExist canonical >>= \exists ->
          pure $ if exists then Right (SafePath canonical)
                           else Left (PathDoesNotExist requested)
    ]
```

File read and write tools take `SafePath`, period. There is no alternative.

**Why it matters:** ZeroClaw had `is_resolved_path_allowed()` in the codebase — it just wasn't called at the file tool call sites (#9). Skill installation created symlinks without path validation (#13). The scanner traversed outside the workspace and read `.env` files (#1435). In PureClaw, forgetting to validate is a type error.

### 4.2 Symlinks must be resolved before validation

`mkSafePath` calls `canonicalizePath` which follows all symlinks. The workspace check is against the resolved path, not the nominal path. There is no path in PureClaw where a symlink escape is possible.

---

## 5. Command Authorization

### 5.1 Unauthorized commands cannot be executed

All subprocess execution in PureClaw flows through `authorize`. The `AuthorizedCommand` type has no public constructor — you cannot execute a command without proof of authorization.

```haskell
module PureClaw.Security.Command
  ( AuthorizedCommand   -- type exported, constructor NOT exported
  , authorize
  , execute
  , CommandError(..)
  ) where

newtype AuthorizedCommand = AuthorizedCommand (FilePath, [Text])

data CommandError
  = CommandNotAllowed Text
  | CommandRateLimited
  | CommandInAutonomyDeny
  deriving (Show, Eq)

authorize :: SecurityPolicy -> FilePath -> [Text] -> IO (Either CommandError AuthorizedCommand)
authorize policy cmd args = do
  let base = takeFileName cmd
  unless (isAllowed policy base) $ throwError (CommandNotAllowed (T.pack base))
  checkRateLimit policy
  pure $ Right (AuthorizedCommand (cmd, args))

execute :: AuthorizedCommand -> IO ProcessResult
execute (AuthorizedCommand (cmd, args)) =
  runProcess $ proc cmd (map T.unpack args)
    & setEnv (Just [])   -- no secret inheritance
```

The cron scheduler, shell tool, and all other execution paths call `authorize` first. There is no direct path to `execute`.

**Why it matters:** ZeroClaw's cron scheduler executed commands without running them through `SecurityPolicy` (#32). iMessage spawned `sqlite3` directly, bypassing policy entirely (#52).

### 5.2 Allow-lists are typed, not stringly-typed

```haskell
data AllowList a
  = AllowAll                -- explicit opt-in to "allow all"
  | AllowList (Set a)       -- explicit set
  deriving (Show, Eq, Generic, FromTOML, ToTOML)

isAllowed :: Ord a => AllowList a -> a -> Bool
isAllowed AllowAll    _ = True
isAllowed (AllowList s) x = Set.member x s
```

TOML parsing maps `allowed_users = ["*"]` to `AllowAll` with a logged warning. There is no ambiguity about what `"*"` means.

**Why it matters:** ZeroClaw's wildcard allowlist behavior was underdocumented and surprised users into accidentally opening channels to all senders (#14). The wildcard was also broken in some configurations (#1406).

---

## 6. Channel Security

### 6.1 Internal details must never reach channel users

All error types have a `toPublicError :: e -> PublicError` conversion that strips internal detail.

```haskell
data PublicError
  = TemporaryError Text    -- "Something went wrong, please try again"
  | RateLimitError         -- "Rate limit reached"
  | NotAllowedError        -- "You are not authorized"
  deriving (Show, Eq)

-- Channel send functions take PublicError, not internal errors
sendError :: Channel -> PublicError -> IO ()

-- Translation strips all internal detail
providerErrorToPublic :: ProviderError -> PublicError
providerErrorToPublic (RateLimit _)      = RateLimitError
providerErrorToPublic (AuthFailure _)    = NotAllowedError
providerErrorToPublic (NetworkError _ _) = TemporaryError "Upstream error"
providerErrorToPublic _                  = TemporaryError "Something went wrong"
```

**Why it matters:** ZeroClaw forwarded raw LLM provider error messages to WhatsApp users and HTTP clients, leaking internal URLs, model names, and partial request bodies (#59, #356).

### 6.2 Tool call output must not leak to channel users

The channel layer receives only the final agent reply text, never intermediate tool call XML/JSON.

```haskell
data AgentOutput
  = AgentReply Text           -- goes to channel
  | ToolCallOutput ToolResult -- stays internal, fed back to agent loop
  | AgentError PublicError    -- goes to channel, stripped of detail

routeOutput :: AgentOutput -> IO ()
routeOutput (AgentReply text)    = sendToChannel text
routeOutput (ToolCallOutput r)   = feedbackToLoop r   -- never to channel
routeOutput (AgentError e)       = sendError e
```

**Why it matters:** ZeroClaw leaked raw tool call JSON to Telegram (#1071) and tool execution commentary to users (#1152).

---

## 7. Gateway Security

### 7.1 Gateway binds localhost only

The gateway binds `127.0.0.1` by default. Binding `0.0.0.0` requires explicit config and emits a startup warning. There is no silent public bind.

```haskell
data GatewayBind
  = LocalhostOnly               -- default
  | PublicBind { withWarning :: Bool }  -- must be explicit

startGateway :: GatewayConfig -> IO ()
startGateway cfg = do
  case gatewayBind cfg of
    PublicBind{} -> logWarn "Gateway bound to 0.0.0.0 — ensure tunnel is in use"
    LocalhostOnly -> pure ()
  warpRun (warpSettings cfg) app
```

### 7.2 Pairing uses cryptographic entropy with per-client lockout

See §1.2 for code. Additionally: failed pairing attempts are tracked per source IP with exponential backoff. Brute-force of a 6-digit code requires ~500k attempts on average; at 5 attempts before lockout, this is infeasible.

```haskell
data PairingState = PairingState
  { attempts   :: TVar (Map IP (Int, UTCTime))
  , validCodes :: TVar (Map PairingCode UTCTime)  -- expires after 5 minutes
  }

attemptPair :: PairingState -> IP -> PairingCode -> IO (Either PairingError BearerToken)
attemptPair st ip code = atomically $ do
  ats <- readTVar (attempts st)
  case Map.lookup ip ats of
    Just (n, t) | n >= 5 -> pure (Left LockedOut)
    _ -> do
      codes <- readTVar (validCodes st)
      if Map.member code codes
        then Right <$> issueToken
        else do
          modifyTVar (attempts st) (Map.insertWith bump ip (1, now))
          pure (Left InvalidCode)
```

**Why it matters:** ZeroClaw's pairing code was brute-forceable (#2). Per-client lockout was also missing initially (#603).

### 7.3 Pairing tokens are hashed at rest, not stored plaintext

```haskell
-- Store SHA-256(token), not token itself
storePairedToken :: TokenStore -> BearerToken -> IO ()
storePairedToken store (BearerToken t) =
  atomically $ modifyTVar store (Set.insert (sha256 t))

verifyPairedToken :: TokenStore -> BearerToken -> IO Bool
verifyPairedToken store (BearerToken t) = do
  hashes <- readTVarIO store
  pure $ Set.member (sha256 t) hashes
```

**Why it matters:** ZeroClaw didn't persist paired token hashes, requiring re-pairing after restart (#604). Worse, early versions stored tokens plaintext.

---

## 8. Memory System Security

### 8.1 Hallucinations must not be stored as facts

The memory auto-save system only stores user-confirmed information and explicit `memory` tool calls. It never automatically stores agent-generated content.

```haskell
data MemorySource
  = UserStatement Text       -- from user message — can be stored
  | ExplicitSave Text        -- from memory tool call — can be stored
  | AgentGenerated Text      -- from agent — NEVER auto-stored

saveToMemory :: MemoryBackend -> MemorySource -> IO (Maybe MemoryId)
saveToMemory backend (UserStatement t)  = Just <$> backend.save t
saveToMemory backend (ExplicitSave t)   = Just <$> backend.save t
saveToMemory _       (AgentGenerated _) = pure Nothing  -- discarded
```

**Why it matters:** ZeroClaw's `auto_save = true` stored model hallucinations as facts, which were then recalled and presented to users as ground truth (#861).

---

## 9. Resource Limits

### 9.1 All external-facing servers must have connection limits

Use `warp` with explicit limits. These are not optional.

```haskell
import Network.Wai.Handler.Warp qualified as Warp

gatewayWarpSettings :: GatewayConfig -> Warp.Settings
gatewayWarpSettings cfg = Warp.defaultSettings
  & Warp.setPort (fromIntegral (gatewayPort cfg))
  & Warp.setHost (fromString (gatewayHost cfg))
  & Warp.setTimeout 30                    -- 30s request timeout
  & Warp.setMaxTotalConnections 100       -- connection cap
```

**Why it matters:** ZeroClaw's raw TCP HTTP server allocated 64KB per connection with no limit — trivially memory-exhaustible (#12).

### 9.2 All regular expressions must be linear-time

Use `regex-tdfa` (POSIX, polynomial worst case) or `re2` bindings (guaranteed linear). The `regex-pcre` crate is banned — PCRE supports backtracking that enables ReDoS.

```haskell
import Text.Regex.TDFA ((=~))

-- Safe: TDFA guarantees polynomial time
matchPattern :: Text -> Text -> Bool
matchPattern pattern input = T.unpack input =~ T.unpack pattern
```

**Why it matters:** ZeroClaw's scanner used unvalidated regex and could be hung indefinitely with crafted input (#1435).

---

## 10. Dependency and Supply Chain

### 10.1 Pin all dependencies

`cabal.project.freeze` is committed and updated deliberately. No floating version bounds in production builds.

### 10.2 Docker images are pinned to digest

```dockerfile
# BANNED: floating tags
FROM debian:bookworm-slim

# REQUIRED: pinned digest
FROM debian@sha256:abc123...
```

**Why it matters:** ZeroClaw's sandbox Dockerfile used a floating base image tag — a supply chain attack vector (#513).

### 10.3 Docker containers never run as root

```dockerfile
RUN useradd -m -u 1000 pureclaw
USER pureclaw
```

**Why it matters:** ZeroClaw's Docker runtime ran as root by default (#34).

---

## Summary Checklist

Before any PR is merged, verify:

- [ ] No new `Show` instances on types containing secrets (use redacted `newtype`)
- [ ] No string interpolation into shell commands (use `proc cmd [args]`)
- [ ] No SQL string construction (use parameterized queries)
- [ ] No `canonicalizePath` call outside of `mkSafePath`
- [ ] All subprocess execution goes through `authorize`
- [ ] No direct reads from files unless path is `SafePath`
- [ ] No crypto outside of `crypton`
- [ ] No `getRandomBytes`-equivalent outside of `Crypto.Random`
- [ ] Warp settings include `setMaxTotalConnections` and `setTimeout`
- [ ] All regex uses `regex-tdfa` or `re2` (not `regex-pcre`)
- [ ] Config serialization doesn't touch `RuntimeConfig`
- [ ] Channel error responses are `PublicError`, not internal types
- [ ] Tool call outputs are not forwarded directly to channels
