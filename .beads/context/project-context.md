# Project Context (Tabs-as-View Refactor — GitHub #79)

## Tooling
- Language: Haskell GHC 9.12.1 (GHC2021), Nix flake
- Build: `nix develop . --command cabal build`
- Test: `nix develop . --command cabal test`
- Coverage: `nix develop . --command cabal test --enable-coverage` (.coverage-thresholds.json = 95%)
- Lint: `nix develop . --command hlint src test`
- Quality: -Wall -Werror (relaxed locally to -Wwarn only at WU8 cutover, restored WU11)

## Conventions
- Handle pattern (records of IO actions); no effect systems (ReaderT/IO); IORef-by-default
- Import style: `qualified as` (no explicit import lists except canonical like `import Data.Set (Set)`)
- Security types: constructors not exported
- New record fields must be added to ALL construction sites (-Werror)
- TDD mandatory: failing test first, commit progression

## Completed Work Units
| WU | Title | Key Files | Notes |
|----|-------|-----------|-------|
| WU7 | Per-conversation relay engine | src/PureClaw/Tabs/Relay.hs | relayOutput 3-mode fan-out, burst de-dup, name-first ping. Additive (replaces ChannelOut gate in WU8). 100% cov. commit 14cc2a8 |
| WU6 | Attach wizard state machine | src/PureClaw/Tabs/Wizard.hs | mkWizardSnapshot/stepWizard, key-bound picks, vanished reprompt, slash-cancel. Additive (WU8 wires interception). 100% cov. commit f15b663 |
| WU5 | SessionPool (refcounted) | src/PureClaw/Tabs/SessionPool.hs | acquire/release, one handle per SessionId, injected open/close. Additive (wired in WU8). 96% cov. commit 22ef367 |
| WU4 | ConversationId through MessageSource | Core/Types.hs, Channels/{CLI,Telegram,Signal}, Handles/Channel + ~12 test files | _ms_conversation required arg; per-channel derivation (Telegram=chat id). commit a4c3e1b |
| WU3 | Persistence + boot reconcile | src/PureClaw/Tabs/Persist.hs | saveTabs/loadTabs, state/tabs.json (0600/0700 atomic), reconcile drops dead-harness tabs. Strict guarded read; PersistDeps injected. 96% cov. commit aa389f9 |
| WU2 | Per-conversation cursors + RelayMode | src/PureClaw/Tabs/Types.hs (+CursorState), Core/Types.hs (Ord ChannelKind) | ConversationKey, RelayMode, CursorState ops; cursors key by TabRef (I3). 100% cov. commit d1bdc54 |
| WU1 | Core registry types + pure ops | src/PureClaw/Tabs/Types.hs, src/PureClaw/Tabs.hs, Core/Types.hs (ConversationId) | TabRef/TabStatus/Tab/opaque TabList (I1/I2/36-cap); TabRegistry IORef handle. 100% cov. commit ad3a1c9 |

## Established Patterns
- Test layout: test/<Area>/NameSpec.hs, module <Area>.NameSpec (NO PureClaw. prefix), spec :: Spec, registered in test/Main.hs + pureclaw.cabal test other-modules.
- Coverage: HPC counts derived (Eq/Ord/Show) instance methods as expressions; exercise them with real assertions OR they show as uncovered. Self-verify via `hpc report` on the .tix before reporting done.
- TabList is OPAQUE (constructor not exported) — callers can't break I1/I2.
- COVERAGE STANDARD (discovered WU4): repo does NOT enforce every-module-95%. IO/transport modules sit far below (Channels.CLI 2%, Telegram 77%, Signal 72%) unwaived on main. Operative bar: NEW logic modules >=95% (Tabs.* all 100%/96%) + no regression on touched modules. Don't block on pre-existing IO debt.
- Prefer total constructions (lazy infinite slotStream + NonEmpty) over partial head/error branches.
- PROVENANCE on the tab path (8d.c / pureclaw-opr): the inbound MessageSource must be captured set-once onto
  the conversation's ACTIVE BOUND session (cursor->ref->store->setSourceIfAbsent), NOT just _env_session
  (foreground). The per-tab transcript provider (Wiring.startProvider) reads that bound session's _sm_source
  per-request so phone+uuid land in BOTH session.json and transcript.jsonl. Mirrors legacy (Just (_im_source msg)).
- CUTOVER DELTAS (intended, classified during 8d.c): the new tabbed path emits NO `model> ` reply prefix
  (WU7 relay name-first ping replaces it) and drops ambient `_env_target=TargetHarness` IRC-prefixed routing
  (superseded by tab-based BoundHarness routing). Per-tab provider output is relayed as streamed chunks
  (_ch_sendChunk), not a single _ch_send — tests of the tabbed path must record both.
- runTabbedLoop is unit-testable: build the 7 tab-subsystem fields via newTabSubsystem (Agent/Env.hs:252);
  drive with a bounded fake channel that throws userError on drain (-> "Session ended" clean exit). See Tabs.WiringSpec.

## Plan & Spec
- Plan: docs/superpowers/plans/2026-06-08-tabs-as-view-refactor.md
- Spec: docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md
