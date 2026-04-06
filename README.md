<p align="center">
  <strong>PureClaw</strong><br>
  <em>Haskell-native AI agent runtime with security-by-construction</em>
</p>

<p align="center">
  <a href="https://github.com/pureclaw/pureclaw/actions/workflows/ci.yml"><img src="https://github.com/pureclaw/pureclaw/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://pureclaw.github.io/pureclaw/coverage/"><img src="https://img.shields.io/badge/coverage-report-blue" alt="Coverage"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSD--3--Clause-green" alt="License"></a>
</p>

---

PureClaw is a complete AI agent runtime where **the insecure path is a compile error**. Shell execution requires `AuthorizedCommand`. File access requires `SafePath`. Secrets have redacted `Show`. If your code compiles, an entire class of security vulnerabilities is structurally impossible.  Haskell's type system does the heavy lifting.

## Quick Start

### Prerequisites

- **Nix** (recommended) &mdash; [install Nix](https://nixos.org/download) for fully reproducible builds
- **Or** GHC 9.10+ and Cabal &mdash; via [GHCup](https://www.haskell.org/ghcup/)
- An API key from [Anthropic](https://console.anthropic.com/), [OpenAI](https://platform.openai.com/), or [OpenRouter](https://openrouter.ai/)

### Install and Run

```bash
# Clone the repository
git clone https://github.com/pureclaw/pureclaw.git
cd pureclaw

# Option 1: Nix (recommended — reproducible, no system deps needed)
nix develop            # enter dev shell with GHC + cabal + hlint
nix build              # build the executable
nix run                # run directly

# Option 2: Cabal (requires GHC toolchain)
cabal build
cabal run pureclaw
```

Binary caches are configured in `flake.nix` — the first Nix build fetches pre-built dependencies rather than compiling from scratch.

### Start a Chat

```bash
# Anthropic (default)
export ANTHROPIC_API_KEY="sk-ant-..."
pureclaw

# OpenAI
export OPENAI_API_KEY="sk-..."
pureclaw --provider openai --model gpt-4o

# Ollama (local, no API key needed)
pureclaw --provider ollama --model llama3

# With tool access and persistent memory
pureclaw --allow git --allow ls --memory sqlite
```

## PureClaw Philosophy

### Mission

To provide a high-integrity **command interface** for autonomous agents—automating the complexity of orchestration while providing the precision visibility required for absolute operational control.

### Vision

To be the industry-standard **orchestration layer** for the agentic era, making the transition from single-agent scripts to complex, multi-agent systems seamless, observable, and inherently safe.

### Core Values

#### **1. Seamless Orchestration (UX)**
PureClaw gives you just the tools you need to command your agents while staying out of your way and giving you a frictionless experience.  It automates the heavy lifting of agent management so developers can focus on building intelligence, not plumbing.

#### **2. Deep Observability (Visibility)**
A command interface is only as good as the data it provides. We utilize **progressive disclosure** to ensure you always have the right level of detail: essential system health at a glance, and deep, tamper-proof audit logs available for forensic investigation.

#### **3. Structural Guardrails (Safety & Security)**
Security should be a property of the system, not a task for the developer. By using type-level enforcement, we transform security from a "policy to remember" into a "structural guarantee," preventing unauthorized actions before they can even be executed.

#### **4. Operational Efficiency (Reliability)**
We design our runtime to be resource-aware. PureClaw prevents "runaway processes" (infinite loops) and "resource exhaustion" (token/compute waste), ensuring that every agent execution is purposeful, predictable, and cost-effective.

## Why PureClaw?

Every major security vulnerability in existing AI agent runtimes shares a root cause: **the insecure path was as easy to write as the secure path**. Security depended on developers remembering to call the right function, add the right check, redact the right field.

PureClaw eliminates these failure modes at the type level:

| Security Property | How It's Enforced | What Fails at Compile Time |
|---|---|---|
| Command authorization | `AuthorizedCommand` proof type | Executing a shell command without policy approval |
| Filesystem confinement | `SafePath` validated path | Accessing files outside the workspace |
| Secret protection | Redacted `Show` on all secret types | Logging or serializing API keys, tokens, pairing codes |
| Policy evaluation | Pure functions, no IO | Security checks that depend on external state |
| Error isolation | `PublicError` channel type | Leaking internal error details to users |
| Capability scoping | Handle pattern | Accessing capabilities not explicitly provided |

See [`docs/SECURITY_PRACTICES.md`](docs/SECURITY_PRACTICES.md) for the full security model, including the real-world production failures each rule prevents.

## Features

### Providers

Connect to any major LLM provider with a single flag:

| Provider | Flag | API Key Env Var |
|---|---|---|
| Anthropic | `--provider anthropic` (default) | `ANTHROPIC_API_KEY` |
| OpenAI | `--provider openai` | `OPENAI_API_KEY` |
| OpenRouter | `--provider openrouter` | `OPENROUTER_API_KEY` |
| Ollama | `--provider ollama` | None (local) |

### Tools

The agent has access to 7 built-in tools, all enforced by the security policy:

| Tool | Description |
|---|---|
| `shell` | Execute shell commands (only commands in the allow-list) |
| `file_read` | Read files within the workspace (SafePath enforced) |
| `file_write` | Write files within the workspace (SafePath enforced) |
| `git` | Git operations: status, diff, log, add, commit, branch, checkout |
| `http_request` | HTTP requests to allowed URLs |
| `memory_store` | Save facts to long-term memory |
| `memory_recall` | Search memory for relevant context |

### Memory Backends

| Backend | Flag | Storage | Best For |
|---|---|---|---|
| None | `--memory none` (default) | &mdash; | Stateless sessions |
| SQLite | `--memory sqlite` | `.pureclaw/memory.db` | Hybrid vector + FTS5 search |
| Markdown | `--memory markdown` | `.pureclaw/memory/` | Human-readable, git-friendly |

### Channels

| Channel | Description |
|---|---|
| CLI | Interactive terminal (default) |
| Telegram | Telegram Bot API integration |
| Signal | Signal messenger via signal-cli |

### Agent Identity (SOUL.md)

Define your agent's personality and constraints with a `SOUL.md` file:

```bash
# Use the default SOUL.md in the current directory
pureclaw

# Or specify a custom identity file
pureclaw --soul ./my-agent.md

# Override with an inline system prompt
pureclaw --system "You are a senior Haskell developer. Be concise."
```

## CLI Reference

```
pureclaw [OPTIONS]

Options:
  -m, --model STRING       Model to use (default: claude-sonnet-4-20250514)
  -p, --provider PROVIDER  LLM provider: anthropic, openai, openrouter, ollama
      --api-key STRING     API key (default: from env var for chosen provider)
  -s, --system STRING      System prompt (overrides SOUL.md)
  -a, --allow CMD          Allow a shell command (repeatable)
      --memory BACKEND     Memory backend: none, sqlite, markdown
      --soul PATH          Path to SOUL.md identity file
  -h, --help               Show help text
```

## Architecture

```
pureclaw/
├── src/PureClaw/
│   ├── Core/            Types, Config, Errors
│   ├── Security/        Path, Command, Policy, Secrets, Crypto, Pairing
│   ├── Handles/         File, Shell, Network, Memory, Channel, Log
│   ├── Tools/           Registry, Shell, FileRead, FileWrite, Git, Memory, Http
│   ├── Agent/           Loop, Context, Memory, Identity
│   ├── Providers/       Anthropic, OpenAI, OpenRouter, Ollama
│   ├── Channels/        CLI, Telegram, Signal
│   ├── Memory/          SQLite, Markdown, None
│   ├── Gateway/         Server, Routes, Auth
│   ├── Scheduler/       Cron, Heartbeat
│   └── CLI/             Commands
├── test/                43 test modules
└── docs/
    ├── ARCHITECTURE.md
    └── SECURITY_PRACTICES.md
```

**Key design decisions:**

- **No effect systems** &mdash; `ReaderT AppEnv IO` and the Handle pattern throughout.
- **Pure policy evaluation** &mdash; `SecurityPolicy` has no IO. Fully testable with QuickCheck.
- **Capability-based handles** &mdash; Each function declares exactly which capabilities it needs. `FileHandle` for file access, `ShellHandle` for execution, `NetworkHandle` for HTTP.
- **Static dispatch** &mdash; Typeclass resolution at compile time. `SomeProvider` and `SomeChannel` existentials only at the CLI wiring boundary.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design.

## Development

### Running Tests

```bash
# Run the full test suite
nix develop --command cabal test

# Run with HPC coverage report
nix develop --command cabal test --enable-coverage

# Run hlint
nix develop --command hlint src/ test/
```

### Project Standards

- **GHC flags:** `-Wall -Werror` with strict warnings (incomplete patterns, name shadowing, unused imports)
- **TDD:** Tests first, implementation second
- **Coverage:** 100% threshold enforcement via `.coverage-thresholds.json`
- **Linting:** hlint clean required before merge
- **CI:** GitHub Actions with Nix builds, HPC coverage reports deployed to [GitHub Pages](https://pureclaw.github.io/pureclaw/coverage/)

### With direnv

```bash
# Auto-enter the Nix dev shell on cd
echo "use flake" > .envrc
direnv allow
```

## Gateway

PureClaw includes an HTTP gateway for programmatic access with built-in security:

- **Cryptographic pairing** &mdash; device enrollment via one-time pairing codes
- **Bearer token auth** &mdash; hex-encoded tokens with constant-time comparison
- **Localhost-only binding** by default (configurable)
- **Connection limits** &mdash; 30s timeout, 100 concurrent connections

## Contributing

Contributions are welcome. Please ensure:

1. All tests pass: `cabal test`
2. hlint is clean: `hlint src/ test/`
3. New code follows existing patterns (Handle pattern, proof-carrying types)
4. Security-sensitive changes include tests demonstrating the invariant holds

## License

BSD-3-Clause &mdash; see [LICENSE](LICENSE) for details.
