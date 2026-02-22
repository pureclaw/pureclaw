# PureClaw

A Haskell-native AI agent runtime with security-by-construction.

## The Problem

Every severe security vulnerability in existing AI agent runtimes shares a root cause: the insecure path was as easy to write as the secure path. Security depended on developers remembering to call the right function.

## The Solution

PureClaw uses Haskell's type system to make the insecure path a **compile error**:

- Shell execution requires `AuthorizedCommand` — no way to bypass policy
- File access requires `SafePath` — workspace escape is impossible to express
- Secrets have redacted `Show` — credential leaks are structurally prevented  
- Security policy is pure Haskell — fully testable, no IO, no side channels
- Effect constraints document capabilities — every function's type is an audit trail

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Security Practices

See [`docs/SECURITY_PRACTICES.md`](docs/SECURITY_PRACTICES.md) — a detailed guide derived from real security failures in production agent runtimes.

## Status

Early development. Security foundations first, features second.

## Building

### With Nix (recommended — fully reproducible)

```bash
# Enter dev shell with GHC + HLS + cabal + ormolu
nix develop

# Build the executable
nix build

# Run directly
nix run

# With direnv (auto-enters dev shell on cd)
direnv allow
```

Binary caches are configured in `flake.nix` — first build fetches from IOG's cache
rather than compiling from scratch.

### With Cabal (requires GHC toolchain)

```bash
cabal build
cabal test
```

Requires GHC 9.10+ (`ghcup` recommended).
