# Haskell Coding Standards

Code style and conventions for the PureClaw project. All agents and contributors must follow these.

---

## Import Style

**Do not use explicit import lists** on most imports. They add visual noise without meaningful safety — the compiler already catches missing or ambiguous names.

```haskell
-- GOOD — clean, readable
import Data.List
import System.Directory
import System.FilePath
import PureClaw.Core.Types
import PureClaw.Security.Policy

-- BAD — bloated, high-maintenance
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, doesPathExist)
import System.FilePath ((</>), isAbsolute, makeRelative, splitDirectories)
import PureClaw.Core.Types (WorkspaceRoot (..), AllowList (..), CommandName (..))
import PureClaw.Security.Policy (SecurityPolicy (..), isCommandAllowed)
```

**Exceptions** — use explicit import lists in these canonical cases:

1. **Importing a single type alongside a qualified import of the same module:**
   ```haskell
   import Data.Set (Set)
   import Data.Set qualified as Set

   import Data.Map (Map)
   import Data.Map qualified as Map

   import Data.Text (Text)
   import Data.ByteString (ByteString)
   ```

2. **Importing a single class that isn't re-exported by Prelude:**
   ```haskell
   import GHC.Generics (Generic)
   ```

**Qualified imports** are always fine and encouraged for modules with common names:
```haskell
import Data.Text qualified as T
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
```

**Export lists** are mandatory (enforced by `-Wmissing-export-lists`). Be explicit about what each module exposes — especially for security types where constructors must not be exported.

---

## Module Structure

Organize each module in this order:

1. Module header with export list
2. Imports (standard library, then external packages, then project-internal)
3. Types
4. Smart constructors / creation functions
5. Operations / business logic
6. Instances (if not derived)

---

## Type Design

- Use `newtype` for domain identifiers and wrapper types — zero runtime cost, type safety at compile time.
- Use `deriving stock` explicitly (project enables `DerivingStrategies`).
- Unexport constructors for security-critical types (`SafePath`, `AuthorizedCommand`, secret newtypes). Provide smart constructors and CPS-style accessors instead.
- Prefer sum types over boolean flags: `AutonomyLevel` not `isAutonomous :: Bool`.

### Record Field Naming

Record fields follow the convention: `_<typeAbbreviation>_<fieldName>`.

- Start with an underscore
- Then an abbreviation of the data type name (lowercase)
- Then another underscore
- Then the field name in camelCase

```haskell
-- GOOD
data SecurityPolicy = SecurityPolicy
  { _sp_allowedCommands :: AllowList CommandName
  , _sp_autonomy        :: AutonomyLevel
  }

data RuntimeConfig = RuntimeConfig
  { _rc_config    :: Config
  , _rc_apiKey    :: ApiKey
  , _rc_secretKey :: SecretKey
  }

data PathError
  = PathEscapesWorkspace FilePath FilePath  -- positional for sum types is fine
  | PathIsBlocked FilePath Text
  | PathDoesNotExist FilePath

-- BAD
data SecurityPolicy = SecurityPolicy
  { policyAllowedCommands :: AllowList CommandName  -- no underscore prefix, verbose
  , policyAutonomy        :: AutonomyLevel
  }
```

### Newtype Deconstructors

Newtypes should have a deconstructor starting with `un` unless there is a more natural name:

```haskell
newtype ParsedDecimal = ParsedDecimal { unParsedDecimal :: Decimal }
newtype ProviderId = ProviderId { unProviderId :: Text }

-- "More natural name" exception:
newtype SafePath = SafePath { getSafePath :: FilePath }
```

---

## Function Design

- Keep functions short. If it's over 30 lines, it probably does too much.
- Prefer pure functions. Push IO to the edges.
- Use guard clauses and early returns over deeply nested `if/then/else`.
- No partial functions (`head`, `tail`, `fromJust`, `read`). Use safe alternatives or pattern matching.

---

## Extensions

Stick to `GHC2021` plus the project defaults:
- `OverloadedStrings`
- `LambdaCase`
- `TupleSections`
- `ScopedTypeVariables`
- `DerivingStrategies`
- `DeriveGeneric`
- `GeneralizedNewtypeDeriving`

Do not add other extensions without discussion. No effect systems, no type-level programming, no GHC extension soup.

---

## Error Handling

- Use `Either` for expected failures. Reserve exceptions for truly exceptional situations.
- Define domain-specific error types, not raw `String` errors.
- Use `PublicError` and `ToPublicError` for anything that might reach a channel user — never expose internal detail.

---

## See Also

- [Architecture](../../docs/ARCHITECTURE.md) — Core design philosophy and module structure
- [Security Practices](../../docs/SECURITY_PRACTICES.md) — Security invariants and banned patterns
- [Testing Patterns](./testing-patterns.md) — TDD patterns and coverage enforcement
