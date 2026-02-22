# PureClaw Architecture

PureClaw is a Haskell-native AI agent runtime. The goal is not feature parity with Rust implementations — it is correctness-by-construction: a system where the type checker enforces security invariants that other runtimes enforce (or fail to enforce) through runtime checks and documentation.

---

## Core Design Philosophy

### Security through types, not discipline

Every severe security issue in existing agent runtimes (see `docs/SECURITY_PRACTICES.md`) shares a root cause: the insecure path was as easy to write as the secure path. The fix was always "remember to call the right function."

PureClaw's answer: make the insecure path a type error.

- You cannot execute a shell command without an `AuthorizedCommand` value.
- You cannot obtain an `AuthorizedCommand` without passing through `SecurityPolicy`.
- You cannot read a file without a `SafePath`.
- You cannot obtain a `SafePath` without canonicalization against the workspace root.
- Secrets cannot appear in log output because their `Show` instances are redacted.
- Config cannot contain secrets because `Config` has no secret fields.

None of these are conventions. They are enforced at compile time.

### IO monad as a capability ledger

In an unconstrained system, any function can do anything: spawn a process, read a file, open a socket. You audit security by reading the entire call graph.

In PureClaw, every function's type signature declares its capabilities:

```haskell
-- This function can ONLY read files. Cannot shell out, cannot network.
readWorkspaceFile :: (FileSystem :> es) => SafePath -> Eff es ByteString

-- This function has NO side effects at all. Trivially auditable.
evaluatePolicy :: SecurityPolicy -> RawCommand -> Either PolicyError AuthorizedCommand
```

Effect constraints are not documentation — they are compiler-enforced contracts. If `evaluatePolicy` ever tried to do IO, it would fail to compile.

### Pure policy evaluation

Security policy is pure Haskell. It takes a command and returns either a proof of authorization or an error. No IO. No side channels. Exhaustively testable with QuickCheck.

```haskell
-- Pure — can be tested with 10,000 QuickCheck cases in milliseconds
evaluatePolicy :: SecurityPolicy -> RawCommand -> Either PolicyError AuthorizedCommand
```

---

## Effect System

PureClaw uses `effectful` for algebraic effects. Choice rationale:

| Library | Status | Performance | Ergonomics |
|---|---|---|---|
| `effectful` | ✅ Production-ready | Fast (state-based) | Clean, minimal boilerplate |
| `polysemy` | Caution | Slow compile times | Heavy TH |
| MTL | Fine | Good | Type class proliferation at scale |

### Effect hierarchy

```
AgentEff              -- full agent stack
├── FileSystem        -- read/write SafePath files
├── Shell             -- execute AuthorizedCommand
├── Network           -- outbound HTTP (allowlisted)
├── Memory            -- recall/store to memory backend
├── ChannelIO         -- send/receive channel messages
├── SchedulerIO       -- interact with cron scheduler
├── Logger            -- structured logging
├── Error AgentError  -- typed errors
└── IOE               -- base IO (minimally used)
```

Each capability is a distinct effect. Tools declare exactly which effects they need:

```haskell
-- Shell tool: needs Shell + FileSystem (for working directory)
runShellTool :: (Shell :> es, FileSystem :> es, Logger :> es)
             => ToolInput -> Eff es ToolOutput

-- Memory tool: needs only Memory
runMemoryTool :: (Memory :> es)
              => ToolInput -> Eff es ToolOutput

-- HTTP tool: needs only Network
runHttpTool :: (Network :> es, Logger :> es)
            => ToolInput -> Eff es ToolOutput
```

The agent loop grants only the effects configured in the security policy. A tool asking for `Shell` when the policy denies shell execution fails to be dispatched — not because of a runtime check, but because the effect isn't in scope.

---

## Core Types

### Secrets

```haskell
-- All secret types: unexported internals, redacted Show
newtype ApiKey       = ApiKey       ByteString
newtype BearerToken  = BearerToken  ByteString
newtype PairingCode  = PairingCode  Text
newtype SecretKey    = SecretKey    ByteString

-- Redacted Show for all secrets — deriving or manual
instance Show ApiKey      where show _ = "ApiKey <redacted>"
instance Show BearerToken where show _ = "BearerToken <redacted>"
instance Show PairingCode where show _ = "PairingCode <redacted>"

-- No ToJSON/ToTOML instances for secrets — they cannot be serialized
```

### Config vs RuntimeConfig

```haskell
-- Serializable: safe to write to disk, contains no secrets
data Config = Config
  { cfgProvider    :: ProviderId
  , cfgModel       :: ModelId
  , cfgGatewayPort :: Port
  , cfgWorkspace   :: FilePath
  , cfgAutonomy    :: AutonomyLevel
  , cfgAllowedCmds :: AllowList CommandName
  , cfgAllowedUsers:: AllowList UserId
  } deriving (Show, Eq, Generic, ToTOML, FromTOML)

-- Not serializable: secrets are runtime-only
data RuntimeConfig = RuntimeConfig
  { rtConfig    :: Config
  , rtApiKey    :: ApiKey    -- from env var or keychain only
  , rtSecretKey :: SecretKey -- for encryption, from keystore
  }
-- No ToTOML/ToJSON instance — compile error if you try to serialize
```

### Path safety

```haskell
-- Constructor unexported — only obtainable via mkSafePath
newtype SafePath = SafePath FilePath

newtype WorkspaceRoot = WorkspaceRoot FilePath

data PathError
  = PathEscapesWorkspace FilePath FilePath -- (requested, resolved)
  | PathIsBlocked        FilePath Text
  deriving (Show, Eq)

-- The ONLY way to get a SafePath
mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
```

### Command authorization

```haskell
-- Constructor unexported — only obtainable via authorize
newtype AuthorizedCommand = AuthorizedCommand (FilePath, [Text])

-- Pure — no IO, fully testable
authorize :: SecurityPolicy -> FilePath -> [Text] -> Either PolicyError AuthorizedCommand

-- Only accepts authorized commands — no other path to subprocess execution
execute :: (Shell :> es) => AuthorizedCommand -> Eff es ProcessResult
```

### Allow-lists

```haskell
data AllowList a
  = AllowAll           -- explicit opt-in; logged as warning on startup
  | AllowList (Set a)
  deriving (Show, Eq, Generic)

-- TOML: allowed_users = ["*"] -> AllowAll (with warning)
--       allowed_users = ["alice", "bob"] -> AllowList {"alice", "bob"}

isAllowed :: Ord a => AllowList a -> a -> Bool
isAllowed AllowAll     _ = True
isAllowed (AllowList s) x = x `Set.member` s
```

### Public errors

```haskell
-- What users see — no internal detail
data PublicError
  = TemporaryError
  | RateLimitError
  | NotAuthorizedError
  deriving (Show, Eq)

-- Channel send accepts only PublicError
sendError :: (ChannelIO :> es) => PublicError -> Eff es ()

-- Internal errors are always translated before reaching a channel
class ToPublicError e where
  toPublicError :: e -> PublicError
```

---

## Module Structure

```
pureclaw/
├── src/
│   ├── PureClaw/
│   │   ├── Core/
│   │   │   ├── Types.hs          -- shared types (no effects)
│   │   │   ├── Config.hs         -- Config / RuntimeConfig
│   │   │   └── Errors.hs         -- error hierarchy
│   │   ├── Security/
│   │   │   ├── Path.hs           -- SafePath, mkSafePath
│   │   │   ├── Command.hs        -- AuthorizedCommand, authorize
│   │   │   ├── Policy.hs         -- SecurityPolicy, evaluatePolicy (PURE)
│   │   │   ├── Secrets.hs        -- ApiKey, BearerToken etc. (redacted Show)
│   │   │   ├── Crypto.hs         -- encryption/decryption via crypton
│   │   │   └── Pairing.hs        -- OTP pairing, per-client lockout
│   │   ├── Effects/
│   │   │   ├── FileSystem.hs     -- FileSystem effect + SafePath handler
│   │   │   ├── Shell.hs          -- Shell effect + AuthorizedCommand handler
│   │   │   ├── Network.hs        -- Network effect + allowlist handler
│   │   │   ├── Memory.hs         -- Memory effect + backends
│   │   │   ├── ChannelIO.hs      -- ChannelIO effect
│   │   │   └── Logger.hs         -- structured logging effect
│   │   ├── Tools/
│   │   │   ├── Registry.hs       -- tool dispatch, capability gating
│   │   │   ├── Shell.hs          -- shell tool (Shell :> es)
│   │   │   ├── FileRead.hs       -- file_read tool (FileSystem :> es)
│   │   │   ├── FileWrite.hs      -- file_write tool (FileSystem :> es)
│   │   │   ├── Memory.hs         -- memory tool (Memory :> es)
│   │   │   ├── HttpRequest.hs    -- http_request tool (Network :> es)
│   │   │   ├── Cron.hs           -- cron tool (SchedulerIO :> es)
│   │   │   └── Git.hs            -- git tool (Shell :> es)
│   │   ├── Agent/
│   │   │   ├── Loop.hs           -- main agent loop
│   │   │   ├── Context.hs        -- conversation context management
│   │   │   ├── Memory.hs         -- memory recall integration
│   │   │   └── Identity.hs       -- SOUL.md / identity config loading
│   │   ├── Providers/
│   │   │   ├── Class.hs          -- Provider typeclass
│   │   │   ├── Anthropic.hs
│   │   │   ├── OpenAI.hs
│   │   │   ├── OpenRouter.hs
│   │   │   └── Ollama.hs
│   │   ├── Channels/
│   │   │   ├── Class.hs          -- Channel typeclass
│   │   │   ├── Telegram.hs
│   │   │   ├── Signal.hs
│   │   │   ├── Discord.hs
│   │   │   └── CLI.hs
│   │   ├── Memory/
│   │   │   ├── Class.hs          -- Memory backend typeclass
│   │   │   ├── SQLite.hs         -- hybrid vector+FTS5 backend
│   │   │   ├── Markdown.hs       -- file-based backend
│   │   │   └── None.hs           -- no-op backend
│   │   ├── Gateway/
│   │   │   ├── Server.hs         -- Warp HTTP server
│   │   │   ├── Routes.hs         -- /health /pair /webhook
│   │   │   └── Auth.hs           -- pairing + bearer token validation
│   │   ├── Scheduler/
│   │   │   ├── Cron.hs           -- cron job management
│   │   │   └── Heartbeat.hs      -- heartbeat loop
│   │   └── CLI/
│   │       ├── Main.hs           -- CLI entry point
│   │       └── Commands.hs       -- subcommand parsers
├── test/
│   ├── Security/
│   │   ├── PolicySpec.hs         -- QuickCheck policy evaluation
│   │   ├── PathSpec.hs           -- SafePath edge cases
│   │   └── CryptoSpec.hs         -- crypto correctness
│   └── ...
├── pureclaw.cabal
├── cabal.project
├── cabal.project.freeze           -- pinned deps, committed
└── docs/
    ├── ARCHITECTURE.md            -- this file
    └── SECURITY_PRACTICES.md
```

---

## Key Architectural Decisions

### 1. Typeclasses for providers and channels

Providers and channels are typeclasses, not trait objects with dynamic dispatch. This keeps the code monomorphic in common configurations while still allowing runtime selection via existential wrappers where needed.

```haskell
class Provider p where
  complete :: p -> CompletionRequest -> IO CompletionResponse
  streamComplete :: p -> CompletionRequest -> IO (Stream CompletionChunk)

class Channel c where
  receive :: c -> IO (Maybe InboundMessage)
  send    :: c -> OutboundMessage -> IO ()
```

### 2. Tool dispatch via existentials

Tools have heterogeneous effect requirements. The registry wraps them as existentials, dispatched by the agent loop with appropriate effect interpretation:

```haskell
data SomeTool where
  MkTool :: (ToolEffects effs) => Tool effs -> SomeTool

-- Agent loop interprets the right effect stack per tool
dispatchTool :: ToolName -> ToolInput -> AgentM ToolOutput
```

### 3. Memory system: hybrid search in SQLite

No external dependencies (no Pinecone, no Elasticsearch). SQLite with FTS5 for keyword search and `sqlite-vec` extension for vector search, with a weighted merge function in Haskell.

```haskell
data SearchResult = SearchResult
  { srContent    :: Text
  , srVector     :: Maybe Float  -- score from vector search
  , srKeyword    :: Maybe Float  -- score from FTS5/BM25
  , srHybrid     :: Float        -- weighted merge
  }

hybridSearch :: MemoryBackend -> Text -> SearchConfig -> IO [SearchResult]
```

### 4. Structured concurrency with `async` + STM

All concurrent operations use `async` with explicit `cancel` and `withAsync` for cleanup. Shared mutable state uses STM only — no `IORef` in concurrent code.

```haskell
-- Daemon runs all subsystems concurrently, cancels all on any failure
runDaemon :: RuntimeConfig -> IO ()
runDaemon cfg = withAsync (runGateway cfg) $ \gatewayA ->
               withAsync (runScheduler cfg) $ \schedulerA ->
               withAsync (runChannels cfg) $ \channelsA ->
               waitAnyCancel [gatewayA, schedulerA, channelsA] >>= \_ ->
               pure ()
```

### 5. Heartbeat as a first-class process

Heartbeat is a distinct async process, not a cron job. It has access to session state and can trigger self-management (context overflow detection, memory flush).

---

## Dependencies

### Core
| Package | Purpose |
|---|---|
| `effectful` | Algebraic effects |
| `aeson` | JSON parsing |
| `tomland` | TOML config parsing |
| `optparse-applicative` | CLI |
| `warp` + `wai` | HTTP server |
| `http-client` + `http-client-tls` | HTTP client |
| `websockets` | WebSocket channels |
| `sqlite-simple` | SQLite memory backend |
| `async` | Structured concurrency |
| `stm` | Shared state |
| `typed-process` | Safe subprocess execution |

### Security
| Package | Purpose |
|---|---|
| `crypton` | AES-256-GCM, random bytes, HMAC |
| `memory` | `constEq` constant-time comparison |
| `bcrypt` | Password hashing (if needed) |

### Data
| Package | Purpose |
|---|---|
| `text` | Text handling |
| `bytestring` | Binary data |
| `containers` | Map, Set, Seq |
| `time` | Time handling |
| `vector` | Dense arrays for embeddings |

### Testing
| Package | Purpose |
|---|---|
| `hspec` | Spec-style tests |
| `QuickCheck` | Property-based testing |
| `hspec-wai` | HTTP endpoint testing |

---

## What PureClaw Is Not

- **Not a Haskell port of ZeroClaw.** ZeroClaw's architecture has security problems baked into its design. We are not translating those decisions into Haskell.
- **Not a thin wrapper over shell scripts.** The shell tool exists for user convenience; it is not the foundation of the system.
- **Not feature-complete on day one.** We build the security core first: `SafePath`, `AuthorizedCommand`, `SecurityPolicy`, `ApiKey` newtypes, `effectful` effect stack. Features are added on top of a correct foundation, not before it.

## What PureClaw Is

A minimal, correct, auditable AI agent runtime where the type checker is the primary security control.
