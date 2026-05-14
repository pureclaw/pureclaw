# Terminal / Backend Abstractions

> ### ⚠️ Important v1 Operating Mode Note
>
> Tmux **Attach mode** (this work) joins the target window as a real tmux
> client — the agent and any human attached to the same window see the
> same screen and share size negotiation. This is **fine for co-pilot
> scenarios** (the human steps back while the agent works) but is **bad
> for autonomous use** where the agent must operate without disturbing a
> live human session. For autonomous, non-intrusive control, wait for
> the deferred **TmuxRpc** mode (see "Two Tmux Operating Modes" and
> "V1 Known Limitations").

## Motivation

PureClaw today can spawn subprocesses (`Handles.Process`, pipe-only) and
drive a tmux pane out-of-band for Claude Code supervision
(`Harness.Tmux`, send-keys/capture-pane). It cannot drive an interactive
shell, drive a remote shell over ssh, or attach to a pre-existing tmux
window. This work adds a uniform abstraction — `BackendHandle` — that
unifies subprocess I/O across pipe-based, PTY-based, local, and remote
modes, so that agents and tools can be written against a single API
regardless of whether the work happens in a local shell, an ssh session,
or a tmux window someone (human or agent) has already prepared.

The abstraction is a record of IO actions (the project's Handle pattern),
tagged with an introspectable kind. Kind-specific behaviour lives behind
the closures.

## Use Cases (agent-facing)

| # | WHO        | WANTS                                                                   | SO THAT                                                                                                  | Success signal                                              |
| - | ---------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1 | An agent   | run a non-interactive program locally (`hostname`, `nix build`)         | one-shot side-effects compose into agent loops                                                           | `RecvSettled` with expected bytes; exit code = 0            |
| 2 | An agent   | drive an interactive program locally inside a real PTY (`bash`, `ghci`) | stateful multi-turn work (cd / pwd, partial REPL eval) stays inside one session                          | multi-turn DoD #2 passes                                    |
| 3 | An agent   | drive an interactive program on a remote host over ssh                  | remote dev boxes / CI hosts / production diagnostic sessions become first-class side-effect targets     | DoD #3 multi-turn passes                                    |
| 4 | An agent   | attach to a pre-existing local tmux window and operate it statefully    | the agent picks up a workflow a human (or earlier agent) already set up; window survives agent disconnect | DoD #6 (window alive after close) passes                    |
| 5 | An agent   | attach to a pre-existing remote tmux window (over ssh) and operate it   | as #4, against remote tmux servers                                                                       | DoD #9 (RemoteHost path) passes                             |

## Use Case (developer-facing)

| # | WHO          | WANTS                                                                | SO THAT                                                                                  |
| - | ------------ | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| 6 | A developer  | swap in `mkNoOpBackendHandle` / `mkInMemoryBackendHandle` for tests | unit tests of agent code paths don't require live shells or remote hosts                  |

## Acceptance Criteria (v1)

The following are enumerable, independently testable Definition-of-Done items.

- [ ] `runBackend` on `mkLocalBackendHandle (authorize p "echo" ["hi"]) defaultPipeOpts` returns `RecvSettled "hi\n"`.
- [ ] `runBackend` on `mkLocalPtyBackendHandle` for `bash` survives `cd /tmp; pwd` as three turns and reports the new cwd.
- [ ] `mkSshBackendHandle` for a configured test host runs the same three-turn `bash` sequence successfully.
- [ ] `mkSshBackendHandle` with an unresolvable host returns `Left (BackendSshConnectFailed _)`; does not throw.
- [ ] `mkSshBackendHandle` constructs an ssh argv that includes `-F /dev/null`, `StrictHostKeyChecking=accept-new`, `BatchMode=yes`, `IdentitiesOnly=yes`, `ConnectTimeout=10`, `ServerAliveInterval=30`, `ForwardX11=no`, `ForwardX11Trusted=no`, `ForwardAgent=no`, no `-X`, no `-Y`, no `-A`.
- [ ] `mkTmuxBackendHandle` with `LocalHost localTmuxCmd` attaches to a pre-existing window, sends a command, captures output, and `_bh_close` detaches without destroying the window. The target window is still present after close.
- [ ] `mkTmuxBackendHandle` with `RemoteHost _ sshCmd remoteTmuxCmd` attaches to a pre-existing remote window over ssh, sends a command, captures output, and `_bh_close` detaches without destroying the window. The remote target window is still present after close (verified by a second short-lived ssh + `tmux list-windows` from the test harness).
- [ ] `mkTmuxBackendHandle` against a non-existent window returns `Left (BackendTmuxTargetMissing _)` and does **not** auto-create the window.
- [ ] `mkTmuxBackendHandle` against an unsafe `TmuxSession` (containing whitespace, shell metacharacters, leading `-`, or NUL) returns `Left (BackendInvalidOption _)` at construction; no subprocess is spawned.
- [ ] `mkTmuxBackendHandle` over `RemoteHost` requires both an outer `AuthorizedCommand` for ssh and an inner `RemoteCommand` for tmux (enforced by type) and surfaces `BackendSshConnectFailed` (not `BackendTmuxTargetMissing`) when the ssh hop itself fails.
- [ ] `mkTmuxBackendHandle` constructs a remote argv whose program path **and** every arg are individually shell-quoted on the remote half. Verifiable with a remote program path containing a space (`/opt/my tools/tmux`).
- [ ] On any backend, `_bh_close` is idempotent (calling twice succeeds both times) and never throws.
- [ ] On any Pty backend, an oversized read (exceeding `_p_to_recvBufferCap`) returns `RecvTruncated`; subsequent `_bh_recv` calls continue to return `RecvTruncated` (the flag latches) until `_bh_close`.
- [ ] `mkNoOpBackendHandle Pty` returns a backend whose `_bh_recv Nothing` yields `RecvSettled ""` and whose `_bh_resize` is a silent no-op. `mkNoOpBackendHandle Pipe` likewise.
- [ ] `mkInMemoryBackendHandle` round-trips bytes deterministically and is the substrate for property tests of `_bh_recv` idle semantics (using a fake clock).
- [ ] An `ssh` host string starting with `-` (e.g. `-oProxyCommand=evil`) is rejected at `mkSshTarget` construction; `BackendInvalidOption`.
- [ ] `Show BackendException` against a wrapped exception whose message contains a hostname or filesystem path does **not** include those values verbatim (redacted by `redactErr`). Same for `Show BackendError` and `Show SshConnectFailure`.
- [ ] All `SecurityPolicy` construction sites in the codebase are updated to set the new `_sp_allowedRemoteCommands :: AllowList CommandName` field. (Construction-site enforcement: `-Werror -Wmissing-fields`. Record-update-site enforcement: `-Werror -Wincomplete-record-updates`. Both flags are already on per project conventions.)
- [ ] Coverage on the new modules meets thresholds in `.coverage-thresholds.json` (100% across lines, branches, functions, statements).
- [ ] Module-level haddock in `PureClaw.Handles.Backend` documents the choose-a-kind decision tree (Pipe vs Pty vs (future) TmuxRpc).

## The Abstraction

```haskell
data BackendKind
  = Pipe        -- one-shot: write stdin, close, read until EOF
  | Pty         -- conversational, PTY-backed, idle-detected
  -- Future: TmuxRpc  -- conversational via send-keys/capture-pane, no PTY
  deriving stock (Eq, Show)

-- | Result of a single recv call. Idle-timeout and EOF are reported, not thrown,
-- so callers can decide whether to retry, keep waiting, or move on.
data RecvResult a
  = RecvSettled   !a               -- output settled within idleQuietMs
  | RecvTimedOut  !a               -- idleTimeoutMs reached; bytes-so-far returned
  | RecvEof       !a               -- subprocess / PTY closed; bytes-so-far returned
  | RecvTruncated !a               -- read-buffer cap reached; bytes truncated; flag LATCHES
  deriving stock (Eq, Show, Functor, Foldable, Traversable)

-- | Accumulated bytes regardless of which outcome.
recvBytes :: RecvResult a -> a
recvBytes = \case
  RecvSettled   a -> a
  RecvTimedOut  a -> a
  RecvEof       a -> a
  RecvTruncated a -> a

-- | Subprocess I/O capability. Record of IO actions; kind-specific behavior
-- lives behind the closures.
data BackendHandle = BackendHandle
  { _bh_name        :: !Text                          -- human-readable, for logs; not identity
  , _bh_kind        :: !BackendKind                   -- introspection
  , _bh_defaultIdle :: !IdleSpec                      -- the IdleSpec bound at construction
  , _bh_send        :: ByteString -> IO ()
  , _bh_recv        :: Maybe IdleSpec -> IO (RecvResult ByteString)
    -- ^ Read output. Nothing = use _bh_defaultIdle; Just s = override for this call.
  , _bh_resize      :: Cols -> Rows -> IO ()          -- no-op on Pipe-kind, future no-op on TmuxRpc
  , _bh_close       :: IO ()                          -- idempotent. NEVER throws.
  }

newtype Cols = Cols Int deriving stock (Eq, Show)
newtype Rows = Rows Int deriving stock (Eq, Show)

runBackend :: BackendHandle -> ByteString -> IO (RecvResult ByteString)
runBackend b bs = _bh_send b bs *> _bh_recv b Nothing

isConversational :: BackendHandle -> Bool
isConversational b = case _bh_kind b of Pipe -> False; Pty -> True
```

> **`runBackend` semantics caveat.** For `Pipe`-kind backends this is a
> true request/response. For `Pty`-kind backends, the response is
> whatever the idle policy captures in response to *this* send, which may
> include unrelated background output (cron messages on a shell prompt,
> async log lines, etc.).

### Stderr handling

- **Pipe kind**: stdout and stderr are merged at the OS level (the child's stderr `dup2`s onto the same pipe as stdout — `setStderr (useHandleOpen stdoutH)` in typed-process). Byte order is preserved.
- **Pty kind**: stderr is not separable — a PTY by design merges both output streams. This is how every terminal works. Documented and tested.
- **Future TmuxRpc**: stderr collapses into capture-pane output.

### Field naming and module placement

- Field naming: `_bh_*` (underscore + 2-letter prefix + camelCase), matching the universal Handle convention (`_fh_*`, `_ph_*`, `_sh_*`, `_hh_*`).
- Type name: `BackendHandle`. Factories: `mk*BackendHandle`, matching `mkProcessHandle` / `mkNoOpProcessHandle`.
- Type, error types, `RecvResult`, `runBackend`, `withBackendHandle*`, `mkNoOpBackendHandle`, `mkInMemoryBackendHandle` live in `PureClaw.Handles.Backend`.
- Real factories live in `PureClaw.Backend.*` (see Module Layout). This split — types in one place, factories in N modules — is an intentional deviation from the single-module Handle pattern, justified by the orthogonal factory families (Local / SSH / Tmux).

## Authorization

Authorization is end-to-end via two non-exported newtypes.

```haskell
-- Existing (Security/Command.hs):
data AuthorizedCommand                  -- constructor NOT exported
authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError AuthorizedCommand

-- New (this work; in PureClaw.Backend.SSH):
data RemoteCommand                      -- constructor NOT exported
authorizeRemote   :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError RemoteCommand
getRemoteProgram  :: RemoteCommand -> FilePath
getRemoteArgs     :: RemoteCommand -> [Text]
```

`authorizeRemote` consults `SecurityPolicy._sp_allowedRemoteCommands`,
which is separate from `_sp_allowedCommands`.

### SecurityPolicy field migration (in scope)

`SecurityPolicy` gains:

```haskell
_sp_allowedRemoteCommands :: AllowList CommandName   -- matches _sp_allowedCommands typing
```

`AllowList` (existing typed allowlist with `AllowAll | AllowList (Set _)`)
preserves the SECURITY_PRACTICES.md §5.2 invariants. Helper functions:

```haskell
isRemoteCommandAllowed :: SecurityPolicy -> CommandName -> Bool
allowRemoteCommand     :: CommandName -> SecurityPolicy -> SecurityPolicy
denyRemoteCommand      :: CommandName -> SecurityPolicy -> SecurityPolicy
```

`defaultPolicy` sets `_sp_allowedRemoteCommands = AllowList Set.empty`
(deny by default). **Every** `SecurityPolicy` construction site must be
updated — `-Werror -Wincomplete-record-updates` makes this a compile error
until fixed. The plan must enumerate every construction site up front
(grep `SecurityPolicy {` across `src/`, `test/`, `app/`).

### v1 login-shell limitation

`mkSshBackendHandle` does **not** support the "ssh into a login shell
with no remote command" mode in v1. Every remote use case is parameterised
by a `RemoteCommand`. Removing the login-shell ambiguity eliminates a
class of "empty-FilePath bypass" bugs (SECURITY_PRACTICES §5.1). Login
shell is a v2 candidate via a typed `RemoteTarget = RemoteProgram
RemoteCommand | RemoteLoginShell LoginShellAuth`.

### Tmux composition: type-enforced authorization

`SshLocation` carries the authorization tokens for whatever side of the
hop they apply to. Local tmux uses `AuthorizedCommand`; remote tmux uses
`RemoteCommand`. The type system makes the right authorization the only
authorization:

```haskell
data SshLocation
  = LocalHost  !AuthorizedCommand                      -- local tmux: local-allowlisted
  | RemoteHost !SshTarget !AuthorizedCommand !RemoteCommand
      -- ^ ssh authorized locally; tmux authorized via authorizeRemote
```

`mkTmuxBackendHandle :: SshLocation -> TmuxTarget -> TmuxOpts -> IO (Either BackendError BackendHandle)`.
The factory cannot be called with a local `AuthorizedCommand` for the
remote inner tmux — it would be a type error.

## SSH Security Defaults

`mkSshBackendHandle` / `mkSshPipeBackendHandle` / `mkTmuxBackendHandle`
(over `RemoteHost`) hardcode this argv prefix — callers cannot opt out:

| Flag                                          | Purpose                                                                       |
| --------------------------------------------- | ----------------------------------------------------------------------------- |
| `-F /dev/null`                                | Do NOT read user `~/.ssh/config`.                                             |
| `-o StrictHostKeyChecking=accept-new`         | First-time fingerprint accepted; subsequent mismatches refused. Never `no`.   |
| `-o UserKnownHostsFile=<projectKnownHosts>`   | Project-scoped (`SafeRuntimePath`). Mode 0600.                                |
| `-o BatchMode=yes`                            | No interactive prompts (works because v1 requires passphrase-less keys).      |
| `-o IdentitiesOnly=yes`                       | Only the explicit `Identity` is offered. No ssh-agent broadcasting.           |
| `-o ConnectTimeout=10`                        | TCP-SYN-phase cap (prevents ~75s OS-default hang on unreachable hosts).       |
| `-o ServerAliveInterval=30`                   | Detect hung peer in ~90s.                                                     |
| `-o ServerAliveCountMax=3`                    | (companion)                                                                   |
| `-o ForwardX11=no`                            | Defensive override (no `-X`).                                                 |
| `-o ForwardX11Trusted=no`                     | Defensive override (no `-Y`).                                                 |
| `-o ForwardAgent=no`                          | Defensive override (no `-A`).                                                 |

### Identity & runtime paths (typed)

Two new path-root types, each with a distinct typed `Safe*Path`. Constructors
of the `Safe*` types are **not** exported.

```haskell
-- Path roots are exported configuration values:
newtype KeysRoot    = KeysRoot    FilePath       -- where ssh identity keys live
newtype RuntimeRoot = RuntimeRoot FilePath       -- where short-lived sockets / known_hosts live

-- Safe paths: constructors NOT exported.
data SafeKeyPath
data SafeRuntimePath

mkSafeKeyPath     :: KeysRoot    -> FilePath -> IO (Either PathError SafeKeyPath)
mkSafeRuntimePath :: RuntimeRoot -> FilePath -> IO (Either PathError SafeRuntimePath)
getSafeKeyPath     :: SafeKeyPath     -> FilePath
getSafeRuntimePath :: SafeRuntimePath -> FilePath
```

`KeysRoot` and `RuntimeRoot` are project-controlled directories outside
the workspace (e.g. `~/.config/pureclaw/keys`, `~/.local/state/pureclaw/run`),
created mode 0700 at startup. The plan must add a setup step that ensures
these directories exist with the right permissions before any
`mkSafe*Path` call.

### SSH host validation

`SshTarget.host` is a validated newtype that rejects:
- leading `-` (defends `-oProxyCommand=evil`-style injection)
- whitespace, shell metacharacters, NUL

```haskell
newtype SshHost = SshHost Text       -- constructor NOT exported
mkSshHost :: Text -> Either BackendError SshHost
```

`SshTarget` uses `SshHost`, not `Text`.

### v1 credential model (passphrase-less keys)

v1 supports only passphrase-less ssh keys:

1. The key file at rest is stored in `VaultHandle`.
2. At construction, the backend writes the decrypted key bytes to an
   ephemeral file under `KeysRoot`, mode 0400, owned by the agent's uid.
3. The factory hands that path as `Identity :: SafeKeyPath` to ssh.
4. On `_bh_close` (and on any construction error after the file was
   written), the file is `unlink`ed and a best-effort overwrite-with-zero
   is attempted before unlink.

> **Honest note on overwrite-with-zero.** On modern copy-on-write
> filesystems (APFS, ZFS, btrfs), journaled filesystems (ext4 with
> data=journal), and SSDs with wear-leveling, the overwrite-with-zero
> step is **defense-in-depth theatre** — the original key bytes likely
> remain recoverable via filesystem internals. The actual mitigation is
> the combination of (a) short lifetime (key file exists only while the
> backend is open), (b) restrictive mode (0400, geteuid-owned), and (c)
> per-process `KeysRoot` outside the workspace. The zero-overwrite is
> retained because it's free and helps on legacy filesystems where it
> still works (FAT, ext4 without journaling, raw HDDs).

This deliberately collapses the `BatchMode=yes` vs `SSH_ASKPASS` conflict
— v1 does not need ASKPASS because there are no passphrases to prompt
for. Passphrase-protected keys + ssh-agent + askpass-helper are explicit
v2 work (see V1 Known Limitations).

## Tmux Target Validation and Pinning

```haskell
newtype TmuxSession = TmuxSession Text
newtype TmuxWindow  = TmuxWindow  Text
newtype TmuxPane    = TmuxPane    Text
-- all three constructors NOT exported

mkTmuxSession :: Text -> Either BackendError TmuxSession
mkTmuxWindow  :: Text -> Either BackendError TmuxWindow
mkTmuxPane    :: Text -> Either BackendError TmuxPane

data TmuxTarget = TmuxTarget
  { _tt_session :: !TmuxSession
  , _tt_window  :: !TmuxWindow
  , _tt_pane    :: !(Maybe TmuxPane)
  }
```

Smart constructors reject: shell metacharacters (`;`, `|`, `&`, `$`,
`` ` ``, `\`, `"`, `'`, `(`, `)`, `<`, `>`, `*`, `?`, `[`, `]`, `{`, `}`,
`!`, `#`, `~`), whitespace including tabs/newlines, leading `-`, and NUL.
Permitted charset: `[A-Za-z0-9_./@:=+-]` (minus leading `-`). The rule is
documented inline in the haddock for each `mkTmuxX` (not only in this
doc).

### Pinning to stable ids (TOCTOU mitigation)

At construction, the Tmux backend resolves `session:window[.pane]` →
`@window_id` (and `%pane_id` if pane was specified) via:

```
tmux <socket-flag?> display-message -p -t '<session>:<window>' '#{window_id}'
```

The output is validated against the regex `^@\d+$` (and `^%\d+$` for
panes) before being stored. If the underlying window is destroyed and
re-created with the same name mid-session, all subsequent
`send-keys`/`capture-pane`/`detach-client` calls use the pinned `@ID` —
they fail closed (`BackendException BackendBrokenTmuxTarget`) rather
than silently writing to the new (potentially different-owner) window.

### Tmux socket pinning

`TmuxOpts` carries `_to_socketPath :: Maybe SafeRuntimePath` to pin the
tmux server socket (`tmux -S /path/to/socket`). When unset, the backend
uses tmux's default; flagged as a v1 limitation on multi-tenant hosts.
**Constraint**: when set, `_to_socketPath` is validated to be on a local
filesystem (no NFS/SMB) — otherwise socket-via-network is an out-of-band
remote-attach vector.

### Remote arg quoting (defense in depth)

`ssh user@host -- tmux ARGS…` re-joins argv on the remote side and
passes it through the remote login shell. The Tmux factory shell-quotes
**every** remote argument — including the program path
(`getRemoteProgram`) — before composing the ssh argv. The quoter lives
in `PureClaw.Internal.ShellQuote`.

**Scope of `Harness.Tmux` migration**: of the three quoting helpers in
`PureClaw.Harness.Tmux` (`shellEscape`, `shellEscapeStr`, `escapeForShell`),
**only `shellEscape` and `shellEscapeStr`** (single-quote-wrapping
canonical form) are migrated to `PureClaw.Internal.ShellQuote`. The
double-quote variant `escapeForShell` and the `sh -c`–based
`stealthShellCommand` are **left in place** in `Harness.Tmux` — they are
specific to the existing Claude Code supervision flow and rewriting them
without a PTY-attach replacement is out of scope. (They will be retired
when the future TmuxRpc work refactors the harness.) A haddock banner is
added to `Harness/Tmux.hs` noting the canonical helper for new code.

## Composition: Tmux-over-SSH at the Command-Line Level

Tmux operated on a remote host runs through ssh. The unified abstraction
handles this **without** any `BackendHandle -> BackendHandle` wrapping.
Composition lives at the command-line level. `ssh -tt` requests a real
remote PTY (the second `-t` forces allocation even when stdin is not a
tty). Spawning `ssh -tt user@host tmux attach-session -t @ID` inside a
local PTY gives a conversational PTY-backed BackendHandle whose remote
end attaches to a pre-existing tmux window:

```
your code → local PTY → ssh client → network → sshd → remote PTY → tmux client
```

## Two Tmux Operating Modes

| Mode             | Mechanism                                          | Kind        | v1?  | Notes                                                                                            |
| ---------------- | -------------------------------------------------- | ----------- | ---- | ------------------------------------------------------------------------------------------------ |
| **Attach**       | `tmux attach -t @ID` inside a PTY                  | `Pty`       | yes  | Joins as a tmux client. **Shares screen** with any human also attached — see "Known Limitations" |
| **RPC** (future) | `tmux send-keys -t @ID` + `tmux capture-pane`      | `TmuxRpc`   | no   | Non-intrusive controller. Stub the abstraction; build later.                                     |

The existing `PureClaw.Harness.Tmux` is the canonical RPC consumer today
and remains untouched. Its `stealthShellCommand` uses `sh -c` (banned in
new code by SECURITY_PRACTICES §3.1) — flagged as tech debt for the
future TmuxRpc refactor; out of scope here. A haddock banner is added to
`Harness/Tmux.hs` pointing readers to this doc.

## Construction Options

Per-constructor option records — every field is meaningful for its kind.

```haskell
-- IdleSpec is a smart-constructor newtype: all values non-negative.
data IdleSpec    -- constructor NOT exported
mkIdleSpec :: Int -> Int -> Int -> Either BackendError IdleSpec
  -- args: idleQuietMs, idleTimeoutMs, idleMinFirstByte
idleQuietMs, idleTimeoutMs, idleMinFirstByte :: IdleSpec -> Int

-- Tiered defaults, exported from PureClaw.Handles.Backend:
localIdle, sshIdle, tmuxIdle, testIdleSpec :: IdleSpec
-- localIdle    ≈ quiet 150ms, total 15s,   minFirstByte 0
-- sshIdle      ≈ quiet 750ms, total 60s,   minFirstByte 500
-- tmuxIdle     ≈ quiet 500ms, total 30s,   minFirstByte 200
-- testIdleSpec ≈ quiet 5ms,   total 50ms,  minFirstByte 0

-- An environment is a Map. Values use a redacted-Show newtype so accidental
-- show'ing of an env doesn't print secrets.
newtype EnvValue = EnvValue ByteString
instance Show EnvValue where show _ = "EnvValue <redacted>"
type EnvMap = Map String EnvValue

-- Names that may not appear in caller-supplied env (set internally only):
forbiddenEnvVars :: Set String      -- LD_PRELOAD, DYLD_INSERT_LIBRARIES, SSH_AUTH_SOCK, SSH_ASKPASS, etc.
mkEnvMap :: [(String, String)] -> Either BackendError EnvMap   -- rejects forbiddenEnvVars

data PtyOpts = PtyOpts
  { _p_to_cols          :: !Cols
  , _p_to_rows          :: !Rows
  , _p_to_env           :: !EnvMap
  , _p_to_cwd           :: !(Maybe FilePath)
  , _p_to_idle          :: !IdleSpec
  , _p_to_recvBufferCap :: !Int
  , _p_to_io            :: !PtyIO        -- injectable PTY allocator (test seam)
  , _p_to_redactor      :: ByteString -> ByteString
  }

data PipeOpts = PipeOpts
  { _po_stdinBytes     :: !ByteString
  , _po_env            :: !EnvMap
  , _po_cwd            :: !(Maybe FilePath)
  , _po_recvBufferCap  :: !Int
  }

data SshOpts = SshOpts
  { _so_pty     :: !PtyOpts             -- for Pty kind; ignored fields documented below
  , _so_control :: !(Maybe ControlOpts) -- ControlMaster opts; Nothing = one-off
  , _so_identity:: !SafeKeyPath         -- ssh identity (v1: passphrase-less)
  }

data SshPipeOpts = SshPipeOpts
  { _spo_env            :: !EnvMap
  , _spo_cwd            :: !(Maybe FilePath)
  , _spo_idle           :: !IdleSpec
  , _spo_recvBufferCap  :: !Int
  , _spo_control        :: !(Maybe ControlOpts)
  , _spo_identity       :: !SafeKeyPath
  }

data ControlOpts = ControlOpts
  { _co_controlPath  :: !SafeRuntimePath
  , _co_persistSecs  :: !Int
  }

data TmuxOpts = TmuxOpts
  { _to_pty        :: !PtyOpts
  , _to_socketPath :: !(Maybe SafeRuntimePath)  -- pin tmux server socket; local-fs only
  }

-- Defaults (exported from PureClaw.Handles.Backend or the kind's home module):
defaultPipeOpts    :: PipeOpts
defaultPtyOpts     :: PtyIO -> PtyOpts        -- caller supplies the PtyIO
defaultSshOpts     :: PtyIO -> SafeKeyPath -> SshOpts
defaultSshPipeOpts :: SafeKeyPath -> SshPipeOpts
defaultTmuxOpts    :: PtyIO -> TmuxOpts
```

`_p_to_env` is the **complete** subprocess environment. The backend adds
`TERM=xterm-256color` and `PATH=/usr/bin:/bin:/usr/local/bin` only if not
already present. No inheritance from the agent's process environment.
This matches SECURITY_PRACTICES §2.4 and `Security/Command.hs` haddock.

`_p_to_redactor` defaults to `defaultCredentialRedactor` (provided by this
work, scrubs known credential prompts — `password:`, `passphrase:`,
`Sorry, try again`, `[sudo] password for`). Opt-out is explicit: set
`_p_to_redactor = id`. This makes the secure path the default path
(SECURITY_PRACTICES §1).

## PTY Test Seam

```haskell
data PtyIO = PtyIO
  { pio_open    :: IO PtyFds                       -- master/slave Fds (real or fake)
  , pio_resize  :: PtyFds -> Cols -> Rows -> IO ()
  , pio_close   :: PtyFds -> IO ()
  }

realPtyIO :: PtyIO                      -- backed by posix-pty
fakePtyIO :: FakePtyConfig -> IO PtyIO  -- IORef-backed; deterministic; under PureClaw.Backend.Pty.Fake

data FakePtyConfig = FakePtyConfig
  { _fpc_clock         :: !FakeClock
  , _fpc_initialOutput :: !ByteString
  , _fpc_eofAfterBytes :: !(Maybe Int)
  }
```

`posix-pty` is firewalled: it is imported **only** from
`PureClaw.Backend.Pty`. A future swap to direct `System.Posix.Terminal`
is then a single-file change.

## In-Memory Test Backend

```haskell
data InMemoryConfig = InMemoryConfig
  { _imc_clock           :: !FakeClock
  , _imc_scriptedReplies :: ![ByteString]   -- consumed in order on each recv
  , _imc_eofAfter        :: !(Maybe Int)    -- terminate after N recvs
  }

mkInMemoryBackendHandle :: BackendKind -> InMemoryConfig -> IO BackendHandle
```

## Factories

```haskell
-- PureClaw.Backend.Local
mkLocalBackendHandle    :: AuthorizedCommand -> PipeOpts -> IO (Either BackendError BackendHandle)
mkLocalPtyBackendHandle :: AuthorizedCommand -> PtyOpts  -> IO (Either BackendError BackendHandle)

-- PureClaw.Backend.SSH
mkSshBackendHandle      :: AuthorizedCommand        -- ssh (local allowlist)
                        -> SshTarget
                        -> RemoteCommand            -- remote program (remote allowlist)
                        -> SshOpts
                        -> IO (Either BackendError BackendHandle)
mkSshPipeBackendHandle  :: AuthorizedCommand
                        -> SshTarget
                        -> RemoteCommand
                        -> SshPipeOpts              -- distinct opts; no ignored fields
                        -> IO (Either BackendError BackendHandle)

-- PureClaw.Backend.Tmux
mkTmuxBackendHandle     :: SshLocation              -- carries the right auth per branch (typed)
                        -> TmuxTarget
                        -> TmuxOpts
                        -> IO (Either BackendError BackendHandle)

-- PureClaw.Handles.Backend
mkNoOpBackendHandle     :: BackendKind -> BackendHandle
mkInMemoryBackendHandle :: BackendKind -> InMemoryConfig -> IO BackendHandle

-- Bracket helpers. Two-tier: one for already-constructed handles, one combined.
withBackendHandle  :: BackendHandle
                   -> (BackendHandle -> IO a)
                   -> IO a                          -- bracket-style; close runs on success or exception
withBackendHandleE :: IO (Either BackendError BackendHandle)
                   -> (BackendHandle -> IO a)
                   -> IO (Either BackendError a)
```

Both `withBackendHandle*` are `bracket`-based: `_bh_close` runs on
success OR exception; body exceptions are re-raised after close.

## Drainer ↔ Recv Signalling

The internal architecture for Pty/Ssh backends:

```haskell
-- Internal to PureClaw.Handles.Backend / PureClaw.Backend.Pty
data RecvSignal
  = RsChunk   !ByteString          -- a chunk of new output
  | RsEof                          -- subprocess exited / PTY closed
  | RsTrunc                        -- buffer cap reached; chunks dropped after this

-- Drainer ⇄ Recv state. STM-based.
data DrainState = DrainState
  { _ds_queue       :: !(TBQueue RecvSignal)   -- bounded queue of chunks + sentinels
  , _ds_truncated   :: !(TVar Bool)            -- latches once flipped
  , _ds_lastByteAt  :: !(TVar (Maybe Time))    -- for idle-quiet measurement
  , _ds_drainerDone :: !(TVar Bool)            -- set when async drainer finishes
  }
```

The drainer reads from the underlying Fd into the queue; on buffer
overflow it sets `_ds_truncated` and stops enqueuing. `_bh_recv`
consumes chunks via STM with `registerDelay` for `idleQuietMs`,
respecting `idleTimeoutMs` as the hard ceiling and `idleMinFirstByte`
as a minimum wait before the idle window opens.

### Idle state machine (explicit)

```
                start
                  │
                  ▼
       ┌──────────────────────────┐
       │   waiting-for-first-byte  │  for at most idleMinFirstByte ms
       └──────────┬───────────────┘
                  │ first chunk arrives
                  ▼
       ┌──────────────────────────┐ ─── idleQuietMs of silence ──> RecvSettled bytes
       │   draining               │ ─── _ds_truncated == True   ──> RecvTruncated bytes (LATCHES)
       │                          │ ─── _ds_drainerDone == True ──> RecvEof bytes
       └──────────┬───────────────┘
                  │ idleTimeoutMs elapsed at any point
                  ▼
            RecvTimedOut bytes
```

Specifically:
- If no bytes arrive within `idleTimeoutMs` total wait, return `RecvTimedOut ""`.
- `idleMinFirstByte` is the *minimum* wait for the first byte before treating "no bytes" as settled (defends against jittery first packets); it does not extend `idleTimeoutMs`.
- `idleQuietMs` is measured from the *latest* byte received (rolling quiet window), not the first.
- `RecvTruncated` latches across `_bh_recv` calls until `_bh_close`.

## Tmux Lifecycle

Typed detach-only close:

```haskell
-- Internal to PureClaw.Backend.Tmux. Constructor NOT exported.
data TmuxCloseAction = TmuxDetach
  -- One-constructor sum. There is no path from TmuxCloseAction to kill-window/session/pane.

issueClose :: TmuxCloseAction -> BackendHandle -> IO ()
issueClose TmuxDetach b = ...  -- writes detach-client key sequence INTO THE EXISTING PTY
```

**Critical:** `_bh_close` writes the detach key sequence to the
**existing** local PTY (which carries the live ssh + tmux client). It
does NOT open a new ssh connection. If the underlying ssh transport is
already dead, the write fails silently (`try @SomeException`) — close
proceeds to cancel the drainer Async and release the local PTY. Close is
idempotent and never throws even when the remote side is unreachable.

An optional best-effort probe (`tmux list-windows` via a *separate*
short-lived ssh hop if `_to_socketPath` is set; otherwise local) can
verify the target window is still present — failure is logged, never
surfaced.

## Lifecycle (other backends)

- **Local (Pipe / Pty)**: `_bh_close` terminates the child + releases PTY. Idempotent.
- **SSH**: `_bh_close` closes the ssh subprocess. With `_so_control = Just _`, the ControlMaster is NOT torn down — `closeSshMultiplex` is separate.
- **Tmux**: see above. Detach only. Never kill.

`_bh_close` is **idempotent** and **never throws** on any backend.

```haskell
-- ControlMaster lifecycle. Caller manages by path; no refcounting in v1.
closeSshMultiplex :: AuthorizedCommand -> ControlOpts -> IO ()
  -- takes the same AuthorizedCommand used to open the multiplex (preserves §5.1 auth invariant)
```

> **v1 ControlMaster caveat.** If you open two `mkSshBackendHandle`s
> against the same `_co_controlPath` and call `closeSshMultiplex` while
> one is still alive, the second backend will hit `BackendException` on
> the next send. Caller-owned lifetimes; no refcounting in v1.

> **v1 ControlMaster + Tmux scope.** `mkTmuxBackendHandle` does **not**
> participate in `ControlMaster` sharing in v1. Every `RemoteHost` tmux
> backend opens a fresh ssh hop with no `-S <controlPath>` flag, even if
> the caller has an active multiplex for the same host via
> `mkSshBackendHandle`. Sharing tmux-over-ssh across a ControlMaster is
> a v2 candidate; the cost in v1 is one extra ssh handshake per tmux
> backend.

## Concurrency

- `_bh_send` and `_bh_recv` MUST NOT be called concurrently from multiple caller threads against the same `BackendHandle`. Callers needing shared access wrap in `MVar BackendHandle`.
- An internal `Async` drainer per Pty/Ssh backend reads PTY/pipe output into the STM-based `DrainState`. `_bh_recv` synchronises via STM.
- `_bh_close` from any thread is safe — drainer is `Async.cancel`led, close action is `try`-wrapped.
- `_bh_send` either succeeds or throws `BackendException`. It NEVER silently swallows.

### Per-process recv buffer cap

In addition to per-backend `_p_to_recvBufferCap`, `PureClaw.Handles.Backend`
maintains a process-wide aggregate cap (default 64 MiB, env-tunable). New
backend factories acquire from a `QSem` keyed on the cap; oversubscribed
construction fails with `BackendError BackendBufferQuotaExceeded`.

## Resource Limits

- `_p_to_recvBufferCap` / `_po_recvBufferCap` bound the per-backend accumulator. Overflow sets the latch; next `_bh_recv` returns `RecvTruncated`. Default: 4 MiB.
- Process-wide aggregate cap: 64 MiB default.
- `idleTimeoutMs` bounds total wait. Tiered defaults (`localIdle`/`sshIdle`/`tmuxIdle`).
- `ConnectTimeout=10` caps ssh TCP-SYN-phase.

## Error Model

```haskell
-- All payload types use redaction-safe structured fields.
newtype CommandName' = CommandName' CommandName   -- reuses existing CommandName
data SshConnectFailure
  = SshNetUnreachable
  | SshAuthRefused
  | SshHostKeyMismatch
  | SshConnectTimeout
  | SshOtherFailure                -- carries an opaque tag, NOT raw stderr
  deriving stock (Eq, Show)
data PtyAllocFailure
  = PtyOpenFailed
  | PtyForkFailed
  | PtyExecFailed
  deriving stock (Eq, Show)
data TmuxTargetRef = TmuxTargetRef !TmuxSession !TmuxWindow !(Maybe TmuxPane)
  deriving stock (Eq, Show)
data InvalidOptionDetail = InvalidOptionDetail !Text   -- carries field name only
  deriving stock (Eq, Show)

data BackendError
  = BackendBinaryNotFound       !CommandName
  | BackendPtyAllocFailed       !PtyAllocFailure
  | BackendSshConnectFailed     !SshConnectFailure
  | BackendTmuxTargetMissing    !TmuxTargetRef
  | BackendInvalidOption        !InvalidOptionDetail
  | BackendBufferQuotaExceeded  !Int     -- requested cap, MiB
  | BackendBrokenTmuxTarget     !TmuxTargetRef   -- runtime: pinned @ID no longer present
  deriving stock (Eq)
instance Show BackendError where
  -- Hand-written: routes through redactErr for any embedded Text and ensures
  -- no raw ssh stderr / hostname / path leaks into the shown form.
  show = T.unpack . redactBackendError

-- Public-error type for user-visible channels.
newtype PublicBackendError = PublicBackendError Text
toPublicError :: BackendError -> PublicBackendError

-- Runtime exceptions. Send and Recv may throw.
data BackendException = BackendException
  { _be_context :: !Text             -- short fixed-vocabulary tag, e.g. "ssh-write"
  , _be_cause   :: !SomeException
  }
instance Show BackendException where
  -- Hand-written: redacts _be_cause via redactErr before formatting.
  show e = T.unpack (redactBackendException e)
instance Exception BackendException
```

The custom `Show` instances are **load-bearing**. The doc-attached
acceptance test asserts that a `BackendException` whose cause embeds a
hostname or identity path does not include those values in its `show`
output.

`redactErr` and `redactBackendError` / `redactBackendException` are
implemented in `PureClaw.Internal.Redact` (new module). They strip
hostnames, IPs, filesystem paths (workspace + keys + runtime roots),
identity-file basenames, and ssh stderr fragments. Tested with property
tests.

## Information Disclosure / Redaction

- `_p_to_redactor` runs on each chunk **after** an internal overlap-window
  coalesce (last 64 bytes carried forward) so a prompt straddling a
  chunk boundary is still matched.
- `defaultCredentialRedactor` ships scrubbers for `password:`,
  `passphrase:`, `Sorry, try again`, `[sudo] password for`. Default on
  for Pty kind (opt out via `_p_to_redactor = id`).
- `Show BackendError` / `Show BackendException` / `Show EnvValue` never
  reveal raw secrets, paths, or hostnames.
- `EnvMap` rejects `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, `SSH_AUTH_SOCK`,
  `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE` at `mkEnvMap`.

## Examples

**Pipe one-shot (Local):**
```haskell
example_pipe :: SecurityPolicy -> IO ()
example_pipe policy = do
  cmd <- either (error "policy: echo not allowed") pure (authorize policy "echo" ["hi"])
  res <- mkLocalBackendHandle cmd defaultPipeOpts
  case res of
    Left  e -> print (toPublicError e)
    Right b -> do
      r <- runBackend b ""
      BS.putStr (recvBytes r)
      _bh_close b
```

**Pty conversational with `withBackendHandleE`:**
```haskell
example_pty :: SecurityPolicy -> PtyIO -> IO ()
example_pty policy pty = do
  cmd <- either (error "policy: bash not allowed") pure (authorize policy "bash" ["-i"])
  res <- withBackendHandleE (mkLocalPtyBackendHandle cmd (defaultPtyOpts pty)) $ \b -> do
    _  <- _bh_recv b Nothing                        -- consume initial prompt
    r1 <- runBackend b "cd /tmp\n"
    r2 <- runBackend b "pwd\n"
    pure (r1, r2)
  print res
```

**SSH Pty (direct, no tmux):**
```haskell
example_ssh_pty :: SecurityPolicy -> PtyIO -> SafeKeyPath -> SshTarget -> IO ()
example_ssh_pty policy pty ident tgt = do
  sshCmd  <- either (error "policy: ssh")  pure (authorize       policy "ssh"  [])
  bashCmd <- either (error "policy: bash") pure (authorizeRemote policy "bash" ["-i"])
  res <- withBackendHandleE (mkSshBackendHandle sshCmd tgt bashCmd (defaultSshOpts pty ident)) $ \b -> do
    _  <- _bh_recv b Nothing                        -- consume initial prompt
    r1 <- runBackend b "uname -a\n"
    r2 <- runBackend b "exit\n"
    pure (r1, r2)
  print res
```

**SSH Pipe one-shot:**
```haskell
example_ssh_pipe :: SecurityPolicy -> SafeKeyPath -> SshTarget -> IO ()
example_ssh_pipe policy ident tgt = do
  sshCmd      <- either (error "policy: ssh")      pure (authorize       policy "ssh" [])
  hostnameCmd <- either (error "policy: hostname") pure (authorizeRemote policy "hostname" [])
  res <- mkSshPipeBackendHandle sshCmd tgt hostnameCmd (defaultSshPipeOpts ident)
  case res of
    Left  e -> print (toPublicError e)
    Right b -> do
      r <- runBackend b ""
      BS.putStr (recvBytes r)
      _bh_close b
```

**Catching runtime exceptions with `try @BackendException`:**
```haskell
example_recover :: BackendHandle -> ByteString -> IO ()
example_recover b input = do
  res <- try @BackendException (runBackend b input)
  case res of
    Right outcome -> case outcome of
      RecvSettled bs   -> BS.putStr bs
      RecvTimedOut bs  -> putStrLn $ "(idle timeout) so-far: " <> show (BS.length bs) <> "B"
      RecvEof bs       -> putStrLn $ "(eof) final: " <> show (BS.length bs) <> "B"
      RecvTruncated bs -> putStrLn $ "(truncated) capped at: " <> show (BS.length bs) <> "B"
    Left e -> do
      -- transport went away mid-conversation; backend is no longer usable
      putStrLn $ "(backend dead: " <> show (toPublicException e) <> ") — caller should reconstruct"
      _bh_close b   -- idempotent; safe to call even if drainer is already gone
```

**Tmux-over-SSH attach:**
```haskell
example_tmux_remote :: SecurityPolicy -> PtyIO -> SafeKeyPath -> IO ()
example_tmux_remote policy pty ident = do
  sshCmd   <- either (error "policy: ssh")  pure (authorize       policy "ssh"  [])
  tmuxCmd  <- either (error "policy: tmux") pure (authorizeRemote policy "tmux" [])
  session  <- either (error "tmux session") pure (mkTmuxSession   "work")
  window   <- either (error "tmux window")  pure (mkTmuxWindow    "0")
  let tgt    = TmuxTarget session window Nothing
      sshLoc = RemoteHost sshTarget sshCmd tmuxCmd
  res <- withBackendHandleE (mkTmuxBackendHandle sshLoc tgt (defaultTmuxOpts pty)) $ \b -> do
    runBackend b "ls\n"
  print res
```

**No-op + in-memory (testing):**
```haskell
example_test :: IO ()
example_test = do
  -- No-op: ignore sends, return empty Settled on recv.
  let nb = mkNoOpBackendHandle Pty
  _ <- runBackend nb "anything\n"
  _bh_close nb

  -- In-memory: deterministic replies + fake clock.
  imc <- pure InMemoryConfig
    { _imc_clock = newFakeClock
    , _imc_scriptedReplies = ["hello\n", "world\n"]
    , _imc_eofAfter = Just 2
    }
  imb <- mkInMemoryBackendHandle Pty imc
  r1  <- runBackend imb "first\n"
  r2  <- runBackend imb "second\n"
  print (recvBytes r1, recvBytes r2)
  _bh_close imb
```

**Per-call idle override (slow remote build):**
```haskell
example_recvWith :: BackendHandle -> IO ()
example_recvWith b = do
  longIdle <- either (error "idle") pure (mkIdleSpec 1000 600_000 0)
  r <- _bh_recv b (Just longIdle)    -- override default for this one call
  print (recvBytes r)
```

**ControlMaster lifecycle:**
```haskell
example_multiplex :: SecurityPolicy -> SafeKeyPath -> ControlOpts -> IO ()
example_multiplex policy ident copts = do
  sshCmd <- either (error "policy") pure (authorize policy "ssh" [])
  let sshOpts = (defaultSshOpts realPtyIO ident) { _so_control = Just copts }
  -- ... use mkSshBackendHandle multiple times sharing copts._co_controlPath ...
  closeSshMultiplex sshCmd copts
```

**Surfacing errors safely (`toPublicError`):**
```haskell
report :: BackendError -> Text
report e = case toPublicError e of PublicBackendError msg -> msg
```

## Taxonomy

```
BackendHandle  (single type; kind selects mechanism)
├── Pipe        — write, close stdin, read EOF
│   Examples: nix build, HTTP CLI, one-shot `ssh host hostname`
│
├── Pty         — conversational; PTY-backed; idle-detected
│   Examples: local bash, ssh -tt user@host, ssh -tt user@host tmux attach …
│
└── TmuxRpc     — (future) conversational; no PTY; send-keys + capture-pane
                  Examples: non-intrusive control of a tmux window someone else owns
```

## Module Layout

```
PureClaw/Handles/Backend.hs       -- BackendHandle, BackendKind, RecvResult, BackendError,
                                  -- BackendException, runBackend, withBackendHandle*,
                                  -- mkNoOpBackendHandle, mkInMemoryBackendHandle, toPublicError,
                                  -- localIdle, sshIdle, tmuxIdle, testIdleSpec, mkIdleSpec,
                                  -- mkEnvMap, defaultCredentialRedactor, defaultPipeOpts,
                                  -- defaultPtyOpts, defaultSshOpts, defaultSshPipeOpts, defaultTmuxOpts
PureClaw/Backend/Pty.hs           -- PtyIO, realPtyIO, fakePtyIO, winsize helpers
                                  -- (ONLY MODULE that imports posix-pty)
PureClaw/Backend/Pty/Fake.hs      -- FakePtyConfig, fake-clock helpers (test-only)
PureClaw/Backend/Local.hs         -- mkLocalBackendHandle, mkLocalPtyBackendHandle
PureClaw/Backend/SSH.hs           -- mkSshBackendHandle, mkSshPipeBackendHandle, SshTarget, SshHost,
                                  -- mkSshHost, SshOpts, SshPipeOpts, ControlOpts, closeSshMultiplex,
                                  -- RemoteCommand, authorizeRemote
PureClaw/Backend/Tmux.hs          -- mkTmuxBackendHandle, TmuxTarget, TmuxSession, TmuxWindow, TmuxPane,
                                  -- mkTmuxSession/Window/Pane, TmuxOpts, SshLocation
PureClaw/Internal/ShellQuote.hs   -- single canonical shell-quoting helper
PureClaw/Internal/Redact.hs       -- redactErr, redactBackendError, redactBackendException
PureClaw/Security/Path.hs         -- (+ SafeKeyPath, mkSafeKeyPath, KeysRoot,
                                  --     SafeRuntimePath, mkSafeRuntimePath, RuntimeRoot)
```

`posix-pty` is a new dependency, firewalled to
`PureClaw.Backend.Pty`. Last upload ~2017; acceptable for v1; tracked as
replacement candidate via direct `System.Posix.Terminal` bindings.

### Module-layout invariant

The plan must enforce: no module outside `PureClaw.Backend.Pty` may
`import Posix.Pty` (verified by a hlint custom rule or a CI grep gate).
This keeps the dep swap a single-file change.

## V1 Known Limitations

These are intentional v1 scope cuts:

- **Tmux Attach shares the screen with humans.** Symptom: when both an agent and a human are attached to the same window, both see all output and both inputs interleave. **Recommendation:** in v1, treat shared attach as "fine for co-pilot scenarios where the human pauses while the agent works; bad for autonomous use." Wait for TmuxRpc when non-intrusive control is required.
- **No SSH reconnect-on-network-blip.** Symptom: a dropped ssh session surfaces as `BackendException` on the next send; previous PTY state is lost. **Workaround:** catch `BackendException`, log via `toPublicError`, re-call `mkSshBackendHandle`.
- **No tmux session/window discovery.** Symptom: callers must already know `session:window`. A `listTmuxTargets` helper is a follow-up.
- **Default tmux socket on multi-tenant hosts.** Symptom: collisions on shared session names. **Recommendation:** always set `_to_socketPath`.
- **Interactive prompts mid-command are not auto-handled.** Symptom: sudo/git-editor/host-key prompts surface in `_bh_recv` output; caller writes the response with `_bh_send`. No built-in expect/respond.
- **Passphrase-protected ssh keys are not supported in v1.** Symptom: a `SafeKeyPath` pointing to a passphrase-protected key produces `BackendSshConnectFailed SshAuthRefused`. **Workaround:** strip the passphrase before storing in Vault. Passphrase + ssh-agent + askpass-helper is v2.
- **No login-shell ssh.** Symptom: `mkSshBackendHandle` always requires a `RemoteCommand`. Use `authorizeRemote p "bash" ["-i"]` to drive an interactive remote shell explicitly. Login-shell sugar is v2.
- **No tmux pin-id migration in `Harness.Tmux`.** Symptom: the existing RPC-style harness remains vulnerable to the same TOCTOU mitigated here for `BackendHandle`. Tracked as follow-up tech debt; will be addressed during the future TmuxRpc work.
- **`posix-pty` upstream dormancy.** Tracked as replacement candidate.

## Coexistence with `Handles.Process`

`PureClaw.Handles.Process` (`ProcessHandle`) is a *registry* of
background processes (`spawn` / `list` / `poll` / `kill` / `writeStdin`).
`BackendHandle` is a *single* subprocess-as-conversation. Both stay in v1.

- Use `ProcessHandle` to track multiple long-running processes by id, or to fire-and-forget a process whose lifetime spans many tool calls.
- Use `BackendHandle` for request/response or conversational I/O against a single subprocess.

The two are complementary; neither subsumes the other.

## Future: TmuxRpc (non-intrusive controller)

Additive:
- New `BackendKind` constructor `TmuxRpc`.
- New `PureClaw/Backend/TmuxRpc.hs` with `mkTmuxRpcBackendHandle`.
- Internally each `_bh_send` shells out `tmux send-keys -t @ID`; each `_bh_recv` polls `tmux capture-pane`. Reuses the shared SSH command-line composition.
- `_bh_resize` and `_bh_close` are no-ops.
- Migration target for `Harness.Tmux`.

## Terminology

| Term                            | Definition                                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **BackendHandle**               | Single abstraction for subprocess I/O. Record of IO actions, tagged with `BackendKind`.                          |
| **Harness**                     | A stateful synchronous tool that gives an LLM the ability to perform side effects.                               |
| **Attach** (tmux)               | Operating mode where the backend acts as a tmux client over a PTY.                                               |
| **RPC** (tmux)                  | Operating mode using `send-keys`/`capture-pane`. PTY-less. Future.                                               |
| **IdleSpec**                    | Construction-time policy for "when has output settled?": quiet-window, hard timeout, min-first-byte.             |
| **RecvResult**                  | `Settled` / `TimedOut` / `Eof` / `Truncated`.                                                                    |
| **SshLocation**                 | `LocalHost AuthorizedCommand` or `RemoteHost SshTarget AuthorizedCommand RemoteCommand`.                         |
| **RemoteCommand**               | Authorized remote program + args; constructor non-exported, obtained only via `authorizeRemote`.                 |
| **TmuxSession/Window/Pane**     | Validated newtypes for tmux selectors. Constructors non-exported.                                                |
| **TmuxCloseAction**             | Internal one-constructor sum that makes "detach only" the only possible close.                                   |
| **PtyIO**                       | Injectable PTY-allocation seam used for testability.                                                             |
| **SafeKeyPath / SafeRuntimePath** | Typed paths against `KeysRoot` / `RuntimeRoot`; distinct from workspace `SafePath`.                            |
| **Cols / Rows**                 | Newtypes around `Int` to avoid argument-order footguns at `_bh_resize`.                                          |
| **`toPublicError`**             | Strips ssh stderr / hostnames / paths from `BackendError` before user-visible surfaces.                          |
| **`defaultCredentialRedactor`** | The default Pty redactor; scrubs known password/passphrase prompt patterns.                                      |
