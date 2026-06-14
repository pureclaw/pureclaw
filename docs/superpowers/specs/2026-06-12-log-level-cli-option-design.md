# Design: `--log-level` CLI option

**Date:** 2026-06-12
**Status:** Approved (design)

## Goal

Add a command-line option that sets the minimum logging severity. Today every
log call (`INFO`, `WARN`, `ERROR`, `DEBUG`) writes to stderr unconditionally;
there is no way to quiet or verbose the output. This adds a single threshold so
the user can choose how much diagnostic output they see.

## Scope

- **In scope:** a `--log-level` CLI flag; a `LogLevel` type; threshold-based
  filtering in the stderr logger.
- **Out of scope:** config-file (`Config.hs`) and environment-variable support,
  per-level enable/disable toggles, runtime level changes, structured/JSON log
  output.

Decided with the user: CLI flag only (no config/env wiring), default level
`Info`.

## Design

### 1. `LogLevel` type — `src/PureClaw/Handles/Log.hs`

```haskell
data LogLevel = Debug | Info | Warn | Error
  deriving (Show, Eq, Ord, Bounded, Enum)
```

Constructor order encodes severity: `Debug < Info < Warn < Error`. Filtering is
"drop any message whose level is below the configured threshold."

A parser helper lives alongside it for the CLI layer:

```haskell
parseLogLevel :: String -> Maybe LogLevel
```

Case-insensitive; accepts `debug`, `info`, `warn`, `error`; returns `Nothing`
for anything else.

### 2. Threshold-filtering logger — `src/PureClaw/Handles/Log.hs`

New constructor that takes the threshold:

```haskell
mkStderrLogHandleAt :: LogLevel -> IO LogHandle
```

Each of the four `LogHandle` fields checks `messageLevel >= threshold` before
writing; a below-threshold call is a no-op. The timestamp/format/locking
behavior is unchanged from the current `mkStderrLogHandle`.

`mkStderrLogHandle` is kept as `mkStderrLogHandleAt Info` so existing call sites
and tests continue to compile. Note this is a behavior change for that
constructor: `DEBUG` messages are now suppressed by default, which matches the
chosen default level.

### 3. CLI wiring — `src/PureClaw/CLI/Commands.hs`

- Add field to `ChatOptions`:

  ```haskell
  _co_logLevel :: Maybe LogLevel
  ```

- Add an option to `chatOptionsParser`:

  ```text
  --log-level LEVEL   Minimum log severity: debug | info | warn | error
                      (default: info)
  ```

  No short flag (avoids colliding with existing single-letter flags). Uses an
  `optparse-applicative` reader backed by `parseLogLevel`, so an invalid value
  fails fast with a non-zero exit and a clear error message.

- In `runChat`, replace `mkStderrLogHandle` with:

  ```haskell
  logger <- mkStderrLogHandleAt (fromMaybe Info (_co_logLevel opts))
  ```

### Semantics

A single threshold, not per-level toggles:

| `--log-level` | DEBUG | INFO | WARN | ERROR |
|---------------|:-----:|:----:|:----:|:-----:|
| `debug`       |  ✅   |  ✅  |  ✅  |  ✅   |
| `info` (default) | ❌ |  ✅  |  ✅  |  ✅   |
| `warn`        |  ❌   |  ❌  |  ✅  |  ✅   |
| `error`       |  ❌   |  ❌  |  ❌  |  ✅   |

## Testing (TDD, 100% coverage required)

1. **`parseLogLevel`** — each valid value (and an upper/mixed-case variant)
   parses; an invalid string returns `Nothing`.
2. **`LogLevel` ordering** — `Debug < Info < Warn < Error`.
3. **`mkStderrLogHandleAt` filtering** — capture stderr; at threshold `Warn`,
   assert `INFO`/`DEBUG` produce no output while `WARN`/`ERROR` do; at threshold
   `Debug`, assert all four write.
4. **CLI integration** (`test/Integration/CLISpec.hs`) — `--log-level` is
   accepted; an invalid value exits non-zero with a clear error; `--help` lists
   the option.

## Risks / Notes

- The `mkStderrLogHandle` default-behavior shift (debug now hidden) is the only
  backward-compatibility consideration. Any test that asserted on DEBUG output
  through `mkStderrLogHandle` must move to `mkStderrLogHandleAt Debug`.
