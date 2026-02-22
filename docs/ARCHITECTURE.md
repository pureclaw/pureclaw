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

### Simple IO, not an effect system

PureClaw uses `ReaderT AppEnv IO` — the standard Handle pattern used in production Haskell. No `effectful`, no `polysemy`, no `mtl` type class proliferation.

The Handle pattern gives us:
- Dependency injection (swap real/mock implementations in tests)
- Scoped capabilities (components only receive the handles they need)
- Easy to read, easy to onboard, no GHC extension soup

Capability control lives in the type signatures of the handles themselves — not in the effect system. A function that only receives a `FileHandle` and `LogHandle` cannot shell out, not because the type system forbids `IO`, but because it has no `ShellHandle` to call. The same principle, far less machinery.

### Pure policy evaluation

Security policy is pure Haskell. It takes a command and returns either proof of authorization or an error. No `IO`. Exhaustively testable with QuickCheck, no mocking required.

```haskell
-- Pure — testable with 10,000 QuickCheck cases in milliseconds
evaluatePolicy :: SecurityPolicy -> FilePath -> [Text] -> Either PolicyError AuthorizedCommand
```

---

## Application Monad

```haskell
type App a = ReaderT AppEnv IO a

data AppEnv = AppEnv
  { envConfig    :: RuntimeConfig
  , envHandles   :: Handles
  , envLogger    :: LogHandle
  }
```

For subsystems that need only a subset of the environment, pass only what they need:

```haskell
-- Shell tool only needs ShellHandle + LogHandle, not the whole env
runShellTool :: ShellHandle -> LogHandle -> ToolInput -> IO ToolOutput
```

This is the Handle pattern: pass explicit handles, not a global environment. Functions are honest about their dependencies via their argument types.

---

## Handles

Each capability is a record of `IO` actions. Swapping implementations (real vs test) is just passing a different record.

```haskell
data FileHandle = FileHandle
  { readFile  :: SafePath -> IO ByteString
  , writeFile :: SafePath -> ByteString -> IO ()
  , listDir   :: SafePath -> IO [SafePath]
  }

data ShellHandle = ShellHandle
  { execute :: AuthorizedCommand -> IO ProcessResult
  }

data NetworkHandle = NetworkHandle
  { httpGet  :: AllowedUrl -> IO Response
  , httpPost :: AllowedUrl -> ByteString -> IO Response
  }

data MemoryHandle = MemoryHandle
  { search :: Text -> SearchConfig -> IO [SearchResult]
  , save   :: MemorySource -> IO (Maybe MemoryId)
  , recall :: MemoryId -> IO (Maybe MemoryEntry)
  }

data LogHandle = LogHandle
  { logInfo  :: Text -> IO ()
  , logWarn  :: Text -> IO ()
  , logError :: Text -> IO ()
  , logDebug :: Text -> IO ()
  }
```

A tool that only receives `FileHandle` and `LogHandle` cannot shell out — not by compiler magic, but because it has no `ShellHandle`. The constraint is in the function signature.

---

## Core Types

### Secrets

```haskell
-- All secret types: unexported internals, redacted Show
newtype ApiKey      = ApiKey      ByteString
newtype BearerToken = BearerToken ByteString
newtype PairingCode = PairingCode Text
newtype SecretKey   = SecretKey   ByteString

instance Show ApiKey      where show _ = "ApiKey <redacted>"
instance Show BearerToken where show _ = "BearerToken <redacted>"
instance Show PairingCode where show _ = "PairingCode <redacted>"
instance Show SecretKey   where show _ = "SecretKey <redacted>"

-- No ToJSON / ToTOML instances — secrets cannot be serialized
```

### Config vs RuntimeConfig

```haskell
-- Serializable: safe to write to disk
data Config = Config
  { cfgProvider    :: ProviderId
  , cfgModel       :: ModelId
  , cfgGatewayPort :: Port
  , cfgWorkspace   :: FilePath
  , cfgAutonomy    :: AutonomyLevel
  , cfgAllowedCmds :: AllowList CommandName
  , cfgAllowedUsers:: AllowList UserId
  } deriving (Show, Eq, Generic, ToTOML, FromTOML)

-- Not serializable: secrets loaded from env / keychain only
data RuntimeConfig = RuntimeConfig
  { rtConfig    :: Config
  , rtApiKey    :: ApiKey    -- no ToTOML instance
  , rtSecretKey :: SecretKey -- no ToTOML instance
  }
-- Attempting to derive ToTOML on RuntimeConfig is a compile error
-- (ApiKey has no ToTOML instance)
```

### Path safety

```haskell
-- Constructor unexported — only obtainable via mkSafePath
newtype SafePath = SafePath FilePath

newtype WorkspaceRoot = WorkspaceRoot FilePath

data PathError
  = PathEscapesWorkspace { requested :: FilePath, resolved :: FilePath }
  | PathIsBlocked        { path :: FilePath, reason :: Text }
  deriving (Show, Eq)

-- The ONLY way to obtain a SafePath
mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) p = do
  canonical <- canonicalizePath (root </> p)
  if root `isPrefixOf` canonical
    then pure $ Right (SafePath canonical)
    else pure $ Left (PathEscapesWorkspace p canonical)
```

### Command authorization

```haskell
-- Constructor unexported — only obtainable via evaluatePolicy
newtype AuthorizedCommand = AuthorizedCommand (FilePath, [Text])

-- Pure — no IO, fully testable
evaluatePolicy :: SecurityPolicy -> FilePath -> [Text] -> Either PolicyError AuthorizedCommand

-- ShellHandle.execute only accepts AuthorizedCommand
-- There is no other path to subprocess execution
```

### Allow-lists

```haskell
data AllowList a
  = AllowAll
  | AllowList (Set a)
  deriving (Show, Eq, Generic)

isAllowed :: Ord a => AllowList a -> a -> Bool
isAllowed AllowAll      _ = True
isAllowed (AllowList s) x = x `Set.member` s
```

### Public errors (channel-safe)

```haskell
-- What users see — no internal detail
data PublicError
  = TemporaryError
  | RateLimitError
  | NotAuthorizedError
  deriving (Show, Eq)

class ToPublicError e where
  toPublicError :: e -> PublicError

-- Channel send only accepts PublicError, never internal errors
sendError :: ChannelHandle -> PublicError -> IO ()
```

---

## Module Structure

```
pureclaw/
├── src/
│   └── PureClaw/
│       ├── Core/
│       │   ├── Types.hs          -- shared types, no IO
│       │   ├── Config.hs         -- Config / RuntimeConfig
│       │   └── Errors.hs         -- error hierarchy
│       ├── Security/
│       │   ├── Path.hs           -- SafePath, mkSafePath
│       │   ├── Command.hs        -- AuthorizedCommand, evaluatePolicy (PURE)
│       │   ├── Policy.hs         -- SecurityPolicy type and combinators
│       │   ├── Secrets.hs        -- ApiKey etc., redacted Show, no serialization
│       │   ├── Crypto.hs         -- AES-256-GCM via crypton
│       │   └── Pairing.hs        -- OTP generation, per-client lockout
│       ├── Handles/
│       │   ├── File.hs           -- FileHandle + real implementation
│       │   ├── Shell.hs          -- ShellHandle + real implementation
│       │   ├── Network.hs        -- NetworkHandle + real implementation
│       │   ├── Memory.hs         -- MemoryHandle (interface)
│       │   ├── Channel.hs        -- ChannelHandle (interface)
│       │   └── Log.hs            -- LogHandle + implementations
│       ├── Tools/
│       │   ├── Registry.hs       -- tool dispatch table
│       │   ├── Shell.hs          -- shell tool (takes ShellHandle)
│       │   ├── FileRead.hs       -- file_read tool (takes FileHandle)
│       │   ├── FileWrite.hs      -- file_write tool (takes FileHandle)
│       │   ├── Memory.hs         -- memory tool (takes MemoryHandle)
│       │   ├── HttpRequest.hs    -- http_request tool (takes NetworkHandle)
│       │   └── Git.hs            -- git tool (takes ShellHandle)
│       ├── Agent/
│       │   ├── Loop.hs           -- main agent loop
│       │   ├── Context.hs        -- conversation context
│       │   ├── Memory.hs         -- memory recall integration
│       │   └── Identity.hs       -- SOUL.md / identity loading
│       ├── Providers/
│       │   ├── Class.hs          -- Provider typeclass
│       │   ├── Anthropic.hs
│       │   ├── OpenAI.hs
│       │   ├── OpenRouter.hs
│       │   └── Ollama.hs
│       ├── Channels/
│       │   ├── Class.hs          -- Channel typeclass
│       │   ├── CLI.hs
│       │   ├── Telegram.hs
│       │   └── Signal.hs
│       ├── Memory/
│       │   ├── SQLite.hs         -- hybrid vector+FTS5 (MemoryHandle impl)
│       │   ├── Markdown.hs       -- file-based (MemoryHandle impl)
│       │   └── None.hs           -- no-op (MemoryHandle impl)
│       ├── Gateway/
│       │   ├── Server.hs         -- Warp, connection limits, timeouts
│       │   ├── Routes.hs         -- /health /pair /webhook
│       │   └── Auth.hs           -- pairing + bearer token validation
│       ├── Scheduler/
│       │   ├── Cron.hs
│       │   └── Heartbeat.hs
│       └── CLI/
│           └── Commands.hs
├── test/
│   ├── Security/
│   │   ├── PolicySpec.hs         -- QuickCheck: pure policy eval
│   │   ├── PathSpec.hs           -- SafePath edge cases
│   │   └── CryptoSpec.hs
│   ├── Agent/
│   │   └── LoopSpec.hs           -- mock handles, no real IO needed
│   └── Gateway/
│       └── RoutesSpec.hs         -- hspec-wai
├── pureclaw.cabal
├── cabal.project
├── cabal.project.freeze
└── docs/
```

---

## Dependencies

### Core
| Package | Purpose |
|---|---|
| `aeson` | JSON |
| `tomland` | TOML config |
| `optparse-applicative` | CLI |
| `warp` + `wai` | HTTP server (connection limits + timeouts built-in) |
| `http-client` + `http-client-tls` | HTTP client |
| `websockets` | Channel WebSockets |
| `sqlite-simple` | Memory backend |
| `async` | Structured concurrency |
| `stm` | Shared state |
| `typed-process` | Safe subprocess execution |

### Security
| Package | Purpose |
|---|---|
| `crypton` | AES-256-GCM, `getRandomBytes`, HMAC |
| `memory` | `constEq` constant-time comparison |

### Testing
| Package | Purpose |
|---|---|
| `hspec` | Tests |
| `QuickCheck` | Property tests (pure policy eval) |
| `hspec-wai` | HTTP endpoint tests |

No `mtl`, no `effectful`, no `polysemy`. The monad stack is `ReaderT AppEnv IO` and that's it.

---

## Relationship to ZeroClaw's Trait Architecture

ZeroClaw's central design insight — every subsystem is a swappable interface — translates
directly and naturally to Haskell typeclasses. Rust traits and Haskell typeclasses solve
the same problem: define a contract that multiple concrete types can satisfy.

ZeroClaw's trait table maps to PureClaw as follows:

| ZeroClaw Trait | PureClaw Typeclass / Handle |
|---|---|
| `Provider` | `class Provider p` — `complete`, `streamComplete` |
| `Channel` | `class Channel c` — `receive`, `send` |
| `Memory` | `class MemoryBackend m` — `search`, `save`, `recall` |
| `Tool` | `class Tool t` — `toolName`, `toolSchema`, `runTool` |
| `Tunnel` | `class Tunnel t` — `start`, `stop`, `endpoint` |
| `RuntimeAdapter` | `class RuntimeAdapter r` — `executeIn`, `sandboxEnv` |
| `Observer` | `class Observer o` — `record`, `flush` |
| `SecurityPolicy` | Pure function — no typeclass needed |

### Where Haskell's typeclasses go further

**Typeclass laws.** Haskell typeclasses can carry documented laws that implementations
must satisfy, testable via QuickCheck. For example, the `MemoryBackend` class can declare:

```haskell
-- Law: save then recall returns the saved entry
-- prop> \entry -> do { mid <- save b entry; recall b mid } == Just entry
class MemoryBackend m where
  save   :: m -> MemorySource -> IO MemoryId
  recall :: m -> MemoryId -> IO (Maybe MemoryEntry)
  search :: m -> Text -> SearchConfig -> IO [SearchResult]
```

ZeroClaw's Rust traits have no equivalent mechanism — correctness of implementations
is documented but not machine-checked.

**Static dispatch by default.** In Rust, swapping implementations at runtime requires
`Box<dyn Trait>` (heap allocation, vtable dispatch). In Haskell, the typeclass is
resolved at compile time via instance selection — zero runtime overhead in the common
case. When runtime dispatch is genuinely needed (e.g. selecting a provider from config),
we use an explicit existential:

```haskell
data SomeProvider where
  MkProvider :: Provider p => p -> SomeProvider
```

This makes the tradeoff explicit at the use site rather than implicit throughout.

**Deriving and default methods.** Haskell's `deriving` and typeclass default methods
reduce boilerplate substantially. A new provider implementation needs only the
non-defaultable methods; everything else composes for free.

### What doesn't change

The _conceptual_ architecture is identical: PureClaw's `Provider`, `Channel`, and
`MemoryBackend` typeclasses represent the same abstraction boundaries as ZeroClaw's
traits. Someone familiar with ZeroClaw's architecture will find PureClaw's module
layout immediately recognizable.

---

## What PureClaw Is Not

- **Not a Haskell port of ZeroClaw.** ZeroClaw's architecture has security problems baked in. We are not translating those decisions into Haskell.
- **Not clever Haskell.** No type-level programming, no GHC extension soup, no effect systems. Standard GHC2021 + `OverloadedStrings` + `LambdaCase`. A competent Haskell programmer should be able to read any module cold.
- **Not feature-complete on day one.** Security foundations first: `SafePath`, `AuthorizedCommand`, `SecurityPolicy`, secret newtypes. Features are added on top of a correct foundation, not before it.

## What PureClaw Is

A minimal, correct, auditable AI agent runtime where the type checker is the primary security control — and where any Haskell programmer can read the code and understand it.
