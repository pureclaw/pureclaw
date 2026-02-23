# Security Foundations Implementation Plan

**Status**: completed
**Epic**: pureclaw-2q1
**Scope**: Core/Types, Security/Secrets, Core/Errors, Security/Policy, Security/Path, Security/Command, Core/Config

## Overview

Implement the type-level security foundation of PureClaw — the core types and security modules that every other module depends on. TDD throughout: tests first, then implementation.

## Explicitly Deferred

`Security.Crypto` and `Security.Pairing` are in the cabal exposed-modules list and architecture doc but are **intentionally deferred** to a later milestone. They depend on cryptographic operations (AES-256-GCM, CSPRNG) and STM state management that belong with the Gateway/Auth work. Their stubs will remain empty. `Gateway.Auth` cannot be implemented until they exist.

## Dependency Order

```
Core/Types (no deps)
  ├── Security/Secrets (depends on Types)
  ├── Core/Errors (depends on Types)
  ├── Security/Policy (depends on Types for AllowList, CommandName)
  ├── Security/Path (depends on Types for WorkspaceRoot)
  ├── Security/Command (depends on Policy, Types)
  └── Core/Config (depends on Types, Secrets, Policy)
```

Note: Path and Command are independent siblings — neither depends on the other.

## Work Units

### WU1: PureClaw.Core.Types
**Files**: `src/PureClaw/Core/Types.hs`, `test/Core/TypesSpec.hs`
**Exports**: `ProviderId(..)`, `ModelId(..)`, `Port(..)`, `AutonomyLevel(..)`, `UserId(..)`, `CommandName(..)`, `ToolCallId(..)`, `MemoryId(..)`, `WorkspaceRoot(..)`, `AllowList(..)`, `isAllowed`
**DoD**:
- [ ] Define: ProviderId, ModelId, Port, UserId, CommandName, ToolCallId, MemoryId newtypes over Text
- [ ] Define: WorkspaceRoot newtype over FilePath
- [ ] Define: AutonomyLevel (Full | Supervised | Deny) sum type
- [ ] Define: AllowList a (AllowAll | AllowList (Set a)) with isAllowed
- [ ] Eq, Ord, Show, Generic instances via deriving strategies
- [ ] Tests: AllowList QuickCheck properties (AllowAll allows everything, AllowList filters correctly, AllowList empty rejects everything)

### WU2: PureClaw.Security.Secrets
**Files**: `src/PureClaw/Security/Secrets.hs`, `test/Security/SecretsSpec.hs`
**Exports**: `ApiKey`, `BearerToken`, `PairingCode`, `SecretKey` (types only, NO constructors), `mkApiKey`, `mkBearerToken`, `mkPairingCode`, `mkSecretKey`, `withApiKey`, `withBearerToken`, `withPairingCode`, `withSecretKey`
**DoD**:
- [ ] Define: ApiKey, BearerToken (newtypes over ByteString), PairingCode (over Text), SecretKey (over ByteString)
- [ ] Constructors NOT exported — only obtainable via mk* smart constructors
- [ ] Redacted Show instances: `show _ = "TypeName <redacted>"`
- [ ] CPS-style accessors: `withApiKey :: ApiKey -> (ByteString -> r) -> r` (prevents secret from escaping via binding)
- [ ] NO ToJSON/FromJSON/ToTOML instances — compile-time guarantee against serialization
- [ ] Tests: Show instances produce redacted output, mk*/with* roundtrip correctly

### WU3: PureClaw.Core.Errors
**Files**: `src/PureClaw/Core/Errors.hs`, `test/Core/ErrorsSpec.hs`
**Exports**: `PublicError(..)`, `ToPublicError(..)`
**DoD**:
- [ ] Define: PublicError (TemporaryError Text | RateLimitError | NotAllowedError) — matches SECURITY_PRACTICES.md §6.1
- [ ] Define: ToPublicError typeclass with `toPublicError :: e -> PublicError`
- [ ] Show, Eq instances
- [ ] Tests: PublicError construction, ToPublicError strips internal detail (example instance for a mock error type)

### WU4: PureClaw.Security.Policy
**Files**: `src/PureClaw/Security/Policy.hs`, `test/Security/PolicySpec.hs`
**Exports**: `SecurityPolicy(..)`, `defaultPolicy`, `allowCommand`, `denyCommand`, `withAutonomy`, `isCommandAllowed`
**DoD**:
- [ ] Define: SecurityPolicy record { policyAllowedCommands :: AllowList CommandName, policyAutonomy :: AutonomyLevel }
- [ ] Policy combinators: defaultPolicy (deny-all), allowCommand, denyCommand, withAutonomy
- [ ] Pure evaluation: isCommandAllowed :: SecurityPolicy -> CommandName -> Bool
- [ ] Tests: QuickCheck properties — defaultPolicy denies everything, allowCommand then isCommandAllowed returns True, denyCommand removes, AllowAll allows everything

### WU5: PureClaw.Security.Path
**Files**: `src/PureClaw/Security/Path.hs`, `test/Security/PathSpec.hs`
**Exports**: `SafePath` (type only, NO constructor), `PathError(..)`, `mkSafePath`, `getSafePath`
**DoD**:
- [ ] Define: SafePath newtype (constructor NOT exported)
- [ ] Define: PathError = PathEscapesWorkspace { requested, resolved } | PathIsBlocked { requested, reason } | PathDoesNotExist FilePath
- [ ] mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
- [ ] Canonicalization via canonicalizePath (follows symlinks)
- [ ] Workspace containment check: resolved path must be prefixed by workspace root
- [ ] Blocked paths: .env, .env.local, .env.production, .ssh, .gnupg, .netrc
- [ ] getSafePath :: SafePath -> FilePath (read-only accessor)
- [ ] Tests: path within workspace succeeds, path escaping fails, blocked paths fail, PathDoesNotExist for missing paths, symlink to outside fails (requires temp dir setup with System.Directory)

### WU6: PureClaw.Security.Command
**Files**: `src/PureClaw/Security/Command.hs`, `test/Security/CommandSpec.hs`
**Exports**: `AuthorizedCommand` (type only, NO constructor), `CommandError(..)`, `authorize`, `getCommandProgram`, `getCommandArgs`
**DoD**:
- [ ] Define: AuthorizedCommand newtype (constructor NOT exported)
- [ ] Define: CommandError = CommandNotAllowed Text | CommandInAutonomyDeny — NO CommandRateLimited (rate limiting is a separate IO concern handled by the Gateway, not the pure policy evaluator)
- [ ] authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError AuthorizedCommand — PURE function
- [ ] Checks: command basename must be in policy's allowed list, autonomy must not be Deny
- [ ] getCommandProgram :: AuthorizedCommand -> FilePath, getCommandArgs :: AuthorizedCommand -> [Text]
- [ ] Note for downstream: ShellHandle.execute will strip the subprocess environment (setEnv (Just [])) — that is a Handle concern, not a Command concern. AuthorizedCommand is proof of policy compliance; environment isolation is execution-time enforcement.
- [ ] Tests: QuickCheck — allowed command authorizes, denied command fails, Deny autonomy rejects all, properties

### WU7: PureClaw.Core.Config
**Files**: `src/PureClaw/Core/Config.hs`, `test/Core/ConfigSpec.hs`
**Exports**: `Config(..)`, `RuntimeConfig`, `mkRuntimeConfig`, `rtConfig`, `rtApiKey`, `rtSecretKey`
**DoD**:
- [ ] Define: Config record { cfgProvider, cfgModel, cfgGatewayPort, cfgWorkspace, cfgAutonomy, cfgAllowedCmds, cfgAllowedUsers }
- [ ] Define: RuntimeConfig (constructor NOT exported — contains secrets)
- [ ] mkRuntimeConfig :: Config -> ApiKey -> SecretKey -> RuntimeConfig
- [ ] Field accessors: rtConfig, rtApiKey, rtSecretKey
- [ ] Show instance for Config (safe — all fields are safe types)
- [ ] Show instance for RuntimeConfig (delegates to Config's Show + redacted secrets)
- [ ] Eq instance for Config only (secrets have no Eq)
- [ ] Tests: Config Show is safe, RuntimeConfig Show redacts secrets, mkRuntimeConfig roundtrips

## Test Infrastructure

Must be done as part of WU1 (before first test run):

1. Add `other-modules` to cabal test suite:
   ```
   other-modules:
     Core.TypesSpec
     Security.SecretsSpec
     Core.ErrorsSpec
     Security.PolicySpec
     Security.PathSpec
     Security.CommandSpec
     Core.ConfigSpec
   ```

2. Add `directory`, `bytestring`, `text`, `containers`, `filepath` to test build-depends (needed for Path IO tests and type construction)

3. Update `test/Main.hs` to import and run all specs explicitly

4. Each WU writes tests FIRST (red), then implements (green)

## Constraints

- GHC2021 + OverloadedStrings + LambdaCase + DerivingStrategies only
- No effect systems, no MTL — plain types and functions
- Constructors for security types (SafePath, AuthorizedCommand, secret newtypes, RuntimeConfig) MUST NOT be exported
- Pure functions where possible (policy evaluation, command authorization)
- `-Wall` clean, explicit export lists on every module
- Subprocess environment stripping is a Handle concern, not defined here — but noted for downstream
