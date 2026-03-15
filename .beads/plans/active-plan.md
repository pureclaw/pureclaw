# Vault Setup + YubiKey/Plugin Support

**Status**: in-progress
**Branch**: age-lib
**Scope**: Vault setup wizard, age plugin detection, rekey, config writer
**Gate iteration**: 3 of 3

## Overview

Replace `/vault init` with `/vault setup` — an interactive wizard that lets users choose their vault encryption mechanism (passphrase or any detected age plugin like YubiKey). Support rekeying existing vaults to change mechanism without losing secrets. Auto-generate plugin identities when needed. Update config file automatically.

## Design Decisions

- **Generic plugin support**: Design around `age-plugin-*` protocol, not YubiKey specifically
- **Vault directory**: All vault files live in `~/.pureclaw/vault/` (vault.age, identity files)
- **No backward compat**: `/vault init` is removed from the slash command registry, replaced entirely by `/vault setup`. The low-level `_vh_init` field on `VaultHandle` remains — it creates an empty vault on disk and is used internally by `/vault setup` and by `unlockAndPutVault`
- **Swappable encryptor**: `VaultState._vst_encryptor` becomes `IORef VaultEncryptor` to support rekey. `VaultState` is internal (not exported) so this is safe
- **Mutable key type in VaultState**: `VaultConfig` stays pure (no IORef). A new `_vst_keyType :: IORef Text` field is added to `VaultState` (internal), initialized from `_vc_keyType` at vault open time. `vaultStatus` reads from the IORef. Rekey updates the IORef
- **Config auto-update**: `/vault setup` writes vault settings to `~/.pureclaw/config.toml` using tomland's bidirectional codec (load → modify → encode → write). Note: this is a full serialize — TOML comments and unknown keys not in `FileConfig` will not be preserved. This is acceptable for a programmatic config file
- **Mutable vault handle in AgentEnv**: `_env_vault` changes from `Maybe VaultHandle` to `IORef (Maybe VaultHandle)` so that `/vault setup` can install a new vault handle at runtime (first-time setup when no vault was configured at startup)
- **Safe rekey protocol**: Rekey writes the new vault file alongside the old one (e.g. `vault.age.new`), verifies both decrypt to identical data, then prompts the user for confirmation before replacing the old file. On cancellation, the new file is deleted and the old encryptor is restored in the IORef

## Dependency Order

```
WU-1: Plugin detection module (no deps)
WU-2: Swappable encryptor + rekey (no deps, parallel with WU-1)
WU-3: Config writer (no deps, parallel with WU-1 and WU-2)
WU-4: /vault setup command (depends on WU-1, WU-2, WU-3)
WU-5: Nix flake + integration test (depends on WU-4)
```

## Work Units

### WU-1: Age Plugin Detection Module

**DoD**:
1. New module `PureClaw.Security.Vault.Plugin` with `AgePlugin` type and `PluginHandle` record
2. `PluginHandle` contains: `_ph_detect :: IO [AgePlugin]` and `_ph_generate :: AgePlugin -> FilePath -> IO (Either VaultError (AgeRecipient, FilePath))`
3. `mkPluginHandle :: IO PluginHandle` — real implementation scanning PATH for `age-plugin-*` binaries and invoking `--generate`
4. `mkMockPluginHandle :: [AgePlugin] -> (AgePlugin -> Either VaultError (AgeRecipient, FilePath)) -> PluginHandle` — mock for tests
5. Known plugin registry with human-readable labels (YubiKey PIV, etc.)
6. Unit tests with mock PluginHandle: detection returns expected plugins, generation returns recipient + identity file path, generation error handling

**File scope**:
- NEW: `src/PureClaw/Security/Vault/Plugin.hs`
- NEW: `test/Security/VaultPluginSpec.hs`
- MODIFY: `pureclaw.cabal` (add `PureClaw.Security.Vault.Plugin` to exposed-modules, `Security.VaultPluginSpec` to test other-modules)

**Key details**:
- `age-plugin-yubikey --generate` outputs lines to stderr with `# public key: age1yubikey1...` and identity string `AGE-PLUGIN-YUBIKEY-1...`
- Parse recipient from `# public key:` comment line
- Identity is all non-comment, non-blank lines
- Write identity to `<dir>/<plugin-name>-identity.txt`
- Plugin detection: split PATH on `:`, list each directory, filter for `age-plugin-*` executables
- `AgePlugin` record: `{ _ap_name :: Text, _ap_binary :: FilePath, _ap_label :: Text }`
- Label lookup from known registry; fallback to binary name for unknown plugins

### WU-2: Swappable Encryptor + Rekey

**DoD**:
1. `VaultState._vst_encryptor` changed from `VaultEncryptor` to `IORef VaultEncryptor`
2. New `_vst_keyType :: IORef Text` field added to `VaultState`, initialized from `_vc_keyType` in `openVault`
3. All 4 direct encryptor access sites updated to use `readIORef`: `vaultInit` (line ~95), `vaultUnlock` (line ~110), `readAndDecryptMap` (line ~230), `encryptAndWrite` (line ~245). (`vaultGet`, `vaultPut`, `vaultDelete` access encryptor indirectly through these helpers)
4. `vaultStatus` reads key type from `_vst_keyType` IORef instead of `_vc_keyType` config field
5. New `_vh_rekey :: VaultEncryptor -> Text -> (Text -> IO Bool) -> IO (Either VaultError ())` added to `VaultHandle`. Args: new encryptor, new key type label, confirmation callback (receives a description string, returns True to proceed)
6. Safe rekey implementation:
   a. Acquire `_vst_writeLock`
   b. Read current encryptor from IORef, decrypt all secrets into plaintext map
   c. Re-encrypt plaintext map with new encryptor, write to `vault.age.new`
   d. Verify: decrypt `vault.age.new` with new encryptor, compare result byte-for-byte with plaintext map. If mismatch → delete `vault.age.new`, return `VaultCorrupted "rekey verification failed"`
   e. Call confirmation callback: "Replace vault? Old: <oldKeyType>, New: <newKeyType>, <N> secrets verified identical"
   f. If confirmed: rename `vault.age.new` → `vault.age` (atomic), update encryptor IORef, update keyType IORef, update TVar cache
   g. If cancelled: delete `vault.age.new`, return `Left (VaultCorrupted "rekey cancelled by user")`
7. Default vault path changed to `~/.pureclaw/vault/vault.age` in `resolveAgeVault` and `resolvePassphraseVault` in `Commands.hs`
8. `VaultConfig` remains pure with `deriving stock (Show, Eq)` — no IORef fields
9. Unit tests: (a) rekey from mock encryptor A to mock encryptor B preserves all secrets, (b) rekey updates key type in status, (c) rekey verification catches mismatch (mock encryptor that produces different output on second encrypt), (d) rekey cancelled by user leaves old vault intact, (e) all existing vault tests still pass with IORef refactor

**File scope**:
- MODIFY: `src/PureClaw/Security/Vault.hs` (IORef encryptor, IORef keyType, rekey with verification + confirmation, openVault, vaultStatus, 4 direct encryptor access sites)
- MODIFY: `src/PureClaw/Agent/Env.hs` (`_env_vault` changes from `Maybe VaultHandle` to `IORef (Maybe VaultHandle)`)
- MODIFY: `src/PureClaw/CLI/Commands.hs` (update default vault path in `resolveAgeVault` line ~574, `resolvePassphraseVault` line ~599, `ensureVaultForOAuth` line ~496; wrap vault in IORef at construction)
- MODIFY: `src/PureClaw/Agent/SlashCommands.hs` (read vault from IORef instead of pattern matching on Maybe directly)
- MODIFY: `test/Security/VaultSpec.hs` (rekey tests including verification and cancellation, verify existing tests pass)
- MODIFY: `test/Agent/SlashCommandsSpec.hs` (add `_vh_rekey` to mock VaultHandle construction, update for IORef vault access)

### WU-3: Config Writer

**DoD**:
1. New function `updateVaultConfig :: FilePath -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> IO ()` that updates vault_path, vault_recipient, vault_identity, vault_unlock fields in config file. `Nothing` means "clear this field" / leave unchanged. First `Maybe Text` is vault_path
2. Implementation: load existing `FileConfig` (or `emptyFileConfig` if file missing), update vault fields, `Toml.encode fileConfigCodec`, write to file
3. Note: full serialize via tomland — TOML comments and keys not in `FileConfig` are not preserved
4. Creates config file if it doesn't exist
5. Unit tests in temp directory: (a) round-trip write then read back, (b) preserves non-vault fields (model, system, providers), (c) creates file from scratch, (d) clears fields with `Nothing`

**File scope**:
- MODIFY: `src/PureClaw/CLI/Config.hs` (add `updateVaultConfig`, add to export list)
- MODIFY: `test/CLI/ConfigSpec.hs` (config writer tests)

### WU-4: /vault setup Command

**DoD**:
1. `VaultSubCommand`: `VaultInit` renamed to `VaultSetup`
2. `/vault setup` replaces `/vault init` in `vaultCommandSpecs` — new description: "Set up or reconfigure the vault encryption mechanism"
3. Interactive flow in `executeVaultCommand`:
   - Call `PluginHandle._ph_detect` to find available plugins
   - Display numbered choices: `1. Passphrase (built-in)`, then one entry per detected plugin with label
   - Read user selection
   - **Passphrase path**: prompt for passphrase, call `_vh_init` (if no vault) or `_vh_rekey` (if vault exists)
   - **Plugin path**: check for existing identity file in vault dir → call `_ph_generate` if missing → call `_vh_init` or `_vh_rekey`
4. Auto-update config via `updateVaultConfig` after successful setup
5. Update `ensureVaultForOAuth` in `Commands.hs` (line ~500): change message from `/vault init` to `/vault setup`
6. Update any other user-facing messages referencing `/vault init` (search for "vault init" across codebase)
7. `_vh_init` field in `VaultHandle` remains unchanged — `/vault setup` calls it internally for new vaults
8. `unlockAndPutVault` remains unchanged — its `_vh_init` fallback still works
9. Vault directory `~/.pureclaw/vault/` created automatically (via `createDirectoryIfMissing True`) before init/setup
10. Unit tests for setup flow with mock PluginHandle and mock VaultHandle

**File scope**:
- MODIFY: `src/PureClaw/Agent/SlashCommands.hs` (VaultSetup command, remove VaultInit from specs, setup handler with first-time-setup support, IORef vault access)
- MODIFY: `src/PureClaw/CLI/Commands.hs` (ensureVaultForOAuth message + default path at line ~496, vault dir creation, IORef vault reads)
- MODIFY: `test/Agent/SlashCommandsSpec.hs` (rename VaultInit → VaultSetup in 4 test references, IORef vault in test setup)
- NEW: `test/Security/VaultSetupSpec.hs` (setup flow tests: first-time passphrase, first-time plugin, rekey with confirmation, rekey cancelled)
- MODIFY: `pureclaw.cabal` (add `Security.VaultSetupSpec` to test other-modules)

**Key details**:
- Setup needs: `ChannelHandle` (for prompts/display), `IORef (Maybe VaultHandle)` (for init/rekey/install), `PluginHandle` (for detection/generation), config file path
- `PluginHandle` constructed ad-hoc in the setup handler via `mkPluginHandle`
- **Encryptor construction**: The setup handler imports and calls:
  - `mkAgeEncryptor` + `ageVaultEncryptor` from `PureClaw.Security.Vault.Age` (for plugin/age key path)
  - `mkPassphraseVaultEncryptor` from `PureClaw.Security.Vault.Passphrase` (for passphrase path)
- **First-time setup** (no vault at startup, `_env_vault` IORef contains `Nothing`):
  1. The `VaultSetup` case in `executeSlashCommand` reads the IORef — if `Nothing`, proceeds to setup flow directly (no early return)
  2. After user picks mechanism, construct `VaultEncryptor` and `VaultConfig`
  3. Call `openVault` to create `VaultHandle`, then `_vh_init` to create empty vault on disk
  4. Write new `VaultHandle` into the `_env_vault` IORef
  5. Update config file
- **Rekey flow** (vault already exists):
  1. Read `VaultHandle` from IORef
  2. Read current status via `_vh_status`
  3. "Vault exists (encrypted with <keyType>). Choose new mechanism:"
  4. Display choices, user picks
  5. Construct new `VaultEncryptor`
  6. Call `_vh_rekey` with new encryptor + confirmation callback (prompts user via ChannelHandle)
  7. Update config file
- **New vault flow** (IORef is `Nothing` or vault file doesn't exist):
  1. "Choose encryption mechanism:"
  2. Display choices, user picks
  3. Construct `VaultEncryptor` and `VaultConfig`, call `openVault` + `_vh_init`
  4. Write new handle into IORef
  5. Update config file

### WU-5: Nix Flake + Integration Test

**DoD**:
1. `age-plugin-yubikey` added to nix flake dev shell `buildInputs` / `nativeBuildInputs`
2. Verify `age-plugin-yubikey` is on PATH in `nix develop .` shell
3. Manual integration test with real YubiKey:
   - Run pureclaw in dev shell
   - Execute `/vault setup`
   - Select YubiKey option
   - Verify identity generation (touch YubiKey when prompted)
   - Store a secret with `/vault add test-key`
   - Retrieve and verify with `/vault list`
   - Verify config file was updated
4. Document any issues or edge cases discovered

**File scope**:
- MODIFY: `flake.nix` (add `age-plugin-yubikey` to shell inputs)

## Human Checkpoints

- After WU-2 (rekey): Review the IORef approach and rekey semantics before building on top
- After WU-4 (setup command): Review the interactive flow UX before integration testing
