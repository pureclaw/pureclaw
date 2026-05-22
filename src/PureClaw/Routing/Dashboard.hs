-- |
-- Module      : PureClaw.Routing.Dashboard
-- Description : Tab dashboard rendering (Tabbed Chat WU9, B1\/B2\/B3).
--
-- Renders the user-facing tab dashboard emitted by the @\/tabs@ (and
-- equivalent @\/tab list@) command.
--
-- == Rendering rules
--
-- * Empty registry (B1) — emits a single helper line:
--
--   @
--   No tabs open. Use \/tab new \<kind\> to create one.
--   @
--
--   Under the tmux packing model, the user does not pick a slot — the
--   factory allocates at the next free index. @\/N@ on a missing tab
--   errors (no auto-spawn), so it is intentionally not advertised
--   here as a way to create tabs.
--
-- * 1 ≤ N \< 8 tabs (B2) — one line per tab, each carrying
--   @index, kind, redacted name, status, asterisk if focused@. The
--   layout uses a leading numeric prefix (@\/0@) followed by a
--   single-space-separated field list so the output renders well in
--   both fixed-width (CLI) and proportional (Telegram \/ Signal) fonts.
--
-- * ≥ 8 tabs (B3) — switches to a bullet-list rendering so the output
--   wraps cleanly on small mobile screens (no fixed-width table).
--
-- == Producer side
--
-- The function returns the formatted body as a single 'Text'; the
-- caller (typically the @\/tabs@ slash-command handler in the
-- dispatcher) wraps the result in 'BannerLine' for emission on
-- '_env_channelOutQ'. Dashboard rendering NEVER reaches the provider
-- and NEVER mutates any tab state (P18 invariant preserved).
--
-- See @docs\/tabbed-chat.md@ §"Dashboard (B-series)" for the spec.
module PureClaw.Routing.Dashboard
  ( -- * Render
    renderDashboard
    -- * Exposed for testing
  , bulletThreshold
  , emptyDashboardText
  ) where

import Control.Exception (SomeException, try)
import Data.IORef (readIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Handles.Tab
  ( TabHandle (..)
  , TabIndex
  , TabKind (..)
  , TabName (..)
  , TabStatus (..)
  , unTabName
  , unPublicTabError
  )
import PureClaw.Session.Kind
  ( HarnessFlavour (..)
  , HarnessSpec (..)
  , ProviderSpec (..)
  , SessionKind (..)
  , TerminalBackend (..)
  )
import PureClaw.Core.Types (unProviderId)


-- | Tab count at or above which the renderer switches from one-line-
-- per-tab to a bullet-style rendering (B3). Exposed for tests so the
-- threshold can be asserted without re-deriving it.
bulletThreshold :: Int
bulletThreshold = 8

-- | Helper text emitted by the empty-registry branch (B1). Exposed for
-- tests so the exact wording can be pinned without re-deriving it.
emptyDashboardText :: Text
emptyDashboardText =
  "No tabs open. Use /tab new <kind> to create one."


-- | Render the tab dashboard.
--
-- Reads '_env_tabs' and '_env_focus' atomically (single IORef each)
-- and consults each tab's '_tabHandle_status' to render the status
-- column. The status read is wrapped in a tolerant 'tryStatus' helper
-- so a misbehaving factory cannot crash the dashboard.
--
-- Output is a single 'Text' with embedded @\\n@ separators between
-- per-tab lines; the caller is responsible for emitting it as a
-- single 'BannerLine'.
renderDashboard :: AgentEnv -> IO Text
renderDashboard env = do
  tabs   <- readIORef (_env_tabs env)
  mFocus <- readIORef (_env_focus env)
  if IntMap.null tabs
    then pure emptyDashboardText
    else do
      let entries = IntMap.toAscList tabs
          useBullets = length entries >= bulletThreshold
      lined <- mapM (renderEntry mFocus useBullets) entries
      pure (T.intercalate "\n" lined)

-- | Render a single registry entry. The format mirrors the design
-- doc's B2 example: @\/I [bullet] kind name status focus-marker@.
renderEntry
  :: Maybe TabIndex
  -> Bool          -- ^ True ⇒ bullet rendering (B3)
  -> (Int, TabHandle)
  -> IO Text
renderEntry mFocus useBullets (key, h) = do
  let idx        = _tabHandle_index h
      kindTxt    = renderKind (_tabHandle_kind h)
      nameTxt    = renderName (_tabHandle_name h)
      idxTxt     = "/" <> T.pack (show key)
      focusMark  = if mFocus == Just idx then " *" else ""
      bulletTxt  = if useBullets then " - " else " "
  statusTxt <- tryStatus h
  pure (idxTxt <> bulletTxt <> kindTxt
                <> " " <> nameTxt
                <> " " <> statusTxt
                <> focusMark)

-- | Render a 'TabKind' as @\<group\>:\<detail\>@ (WU-11 C5).
--
-- Examples: @provider:anthropic@, @harness:claude-code@, @shell:local@,
-- @shell:ssh@, @shell:tmux@, @shell:container@.
renderKind :: TabKind -> Text
renderKind k = case k of
  TkSession (SkProvider ps)  -> "provider:" <> unProviderId (_ps_provider ps)
  TkSession (SkHarness hs)   -> "harness:"  <> renderFlavour (_h_flavour hs)
  TkRawShell TbLocal         -> "shell:local"
  TkRawShell (TbSsh _)       -> "shell:ssh"
  TkRawShell (TbTmux _)      -> "shell:tmux"
  TkRawShell (TbContainer _) -> "shell:container"

-- | Render a 'HarnessFlavour' as its user-facing label.
renderFlavour :: HarnessFlavour -> Text
renderFlavour f = case f of
  HClaudeCode -> "claude-code"
  HCodex      -> "codex"
  HOpenCode   -> "opencode"
  HHermes     -> "hermes"
  HPureClaw   -> "pureclaw"
  HCustom n   -> n

-- | Project a 'TabName' to its render-safe text. The 'TabName' newtype
-- guarantees H11 (sanitised), so this is just the unwrap.
renderName :: TabName -> Text
renderName = unTabName

-- | Read '_tabHandle_status' tolerantly. The status field is in IO;
-- a buggy factory could throw. The dashboard collapses any exception
-- into the short label @\"?\"@ so the rendering never crashes the
-- caller.
tryStatus :: TabHandle -> IO Text
tryStatus h = do
  r <- try @SomeException (_tabHandle_status h)
  pure $ case r of
    Left  _ -> "?"
    Right s -> renderStatus s

-- | Render a 'TabStatus' as its short user-visible label.
renderStatus :: TabStatus -> Text
renderStatus s = case s of
  Active      -> "active"
  Idle _      -> "idle"
  Crashed pe  -> "crashed (" <> unPublicTabError pe <> ")"
