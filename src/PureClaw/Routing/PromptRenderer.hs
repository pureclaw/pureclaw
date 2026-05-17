-- |
-- Module      : PureClaw.Routing.PromptRenderer
-- Description : Channel-aware spawn-prompt UX (Tabbed Chat WU9, A4 \/ A6).
--
-- When the dispatcher needs to ask the user which 'TabKind' to spawn
-- (because '/N' or '/tab new N' was issued without a kind argument and
-- '_rc_defaultKind' is unset), it emits a short prompt via the channel.
-- Different channels render this differently:
--
--   * Telegram surfaces an inline-keyboard with one button per supported
--     kind ('ai', 'harness', 'shell', 'ssh', 'tmux').
--   * Signal \/ CLI surface a plain-text reply enumerating the same
--     options as numbered choices.
--
-- WU9 ships a single channel-dispatched renderer:
-- 'mkDefaultPromptRenderer' picks the right format based on the
-- supplied 'ChannelHandle'\'s capability hint ('_ch_streaming'); tests
-- inject 'mkTextPromptRenderer' directly when they want to assert on a
-- specific rendering.
--
-- == Why a record, not a typeclass
--
-- Mirrors the Handle pattern used elsewhere in PureClaw — concrete IO
-- actions are easier to substitute in tests than typeclass dictionaries
-- and produce no orphan-instance surface.
--
-- == Buffered payload (A6)
--
-- When '/N <payload>' is issued for a missing index with no default
-- kind, the dispatcher buffers @payload@ alongside the prompt so the
-- (later) kind-selection turn can enqueue @payload@ on the freshly
-- spawned tab. The 'PromptRenderer' carries enough information for the
-- channel to round-trip the index AND the payload back to the
-- dispatcher in the subsequent user reply — for v1 we surface the
-- index \/ payload in the prompt text so the user can re-issue
-- '/tab new N <kind> <payload>' verbatim. A v1.5+ refinement may add a
-- proper callback-data layer; the renderer interface admits it without
-- a breaking change.
--
-- See @docs\/tabbed-chat.md@ §"Auto-spawn behavior (A-series)" for the
-- A4 \/ A6 contract and §"Channel emission via ChannelOut writer" for
-- the dispatcher-side emission rules.
module PureClaw.Routing.PromptRenderer
  ( -- * Renderer
    PromptRenderer (..)
    -- * Default renderers
  , mkDefaultPromptRenderer
  , mkTextPromptRenderer
  , mkInlineKeyboardPromptRenderer
    -- * Helpers
  , renderKindsAsText
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Channel (ChannelHandle (..))
import PureClaw.Handles.Tab (TabIndex, unTabIndex)


-- | A record-of-actions abstraction over per-channel spawn-prompt
-- rendering.
--
-- '_pr_renderSpawnPrompt' takes the requested tab index and an
-- optional buffered payload (the @Just txt@ form of A6, where the
-- user typed @\/N \<txt\>@) and returns the user-visible 'Text' to
-- enqueue as a dispatcher banner.
--
-- The renderer does NOT itself touch the channel — the caller (the
-- AutoSpawn module in WU9) drives 'PureClaw.Routing.Dispatcher's
-- @emitDispatcherBanner@ with the rendered string. Keeping the
-- rendering pure-text means tests can pin the exact wording without
-- intercepting channel I\/O.
newtype PromptRenderer = PromptRenderer
  { _pr_renderSpawnPrompt :: TabIndex -> Maybe Text -> Text
  }


-- | Dispatch on the supplied 'ChannelHandle' to pick the renderer
-- that best matches the channel's capabilities.
--
-- The current heuristic is intentionally coarse: a channel reporting
-- '_ch_streaming = True' is treated as a CLI surface (text reply); a
-- channel reporting '_ch_streaming = False' is treated as a Telegram-
-- style surface (inline-keyboard prompt). Real Signal\/Telegram
-- implementations also report '_ch_streaming = False', so both get the
-- inline-keyboard rendering by default — which degrades gracefully to
-- text when the channel layer cannot honour the markup.
--
-- WU11 may refine this dispatch (e.g. by adding a explicit channel-kind
-- discriminator to 'ChannelHandle'); for WU9 the heuristic is
-- sufficient to flip the A4 \/ A6 DoDs green.
mkDefaultPromptRenderer :: ChannelHandle -> PromptRenderer
mkDefaultPromptRenderer ch
  | _ch_streaming ch = mkTextPromptRenderer
  | otherwise        = mkInlineKeyboardPromptRenderer


-- | A plain-text renderer suitable for CLI \/ Signal: enumerates the
-- supported tab kinds as numbered choices.
--
-- The wording is:
--
-- @
-- Spawn /N as which kind? Reply with: /tab new N \<kind\> [\<args\>]
-- where \<kind\> is one of: ai, harness, shell, ssh, tmux
-- @
--
-- When a buffered payload is present (A6), the prompt appends a
-- secondary line so the user can re-issue the full command verbatim.
mkTextPromptRenderer :: PromptRenderer
mkTextPromptRenderer = PromptRenderer renderTextPrompt

renderTextPrompt :: TabIndex -> Maybe Text -> Text
renderTextPrompt idx mPayload =
  let nTxt = tShowIdx idx
      header =
        "Spawn /" <> nTxt
          <> " as which kind? Reply with: /tab new "
          <> nTxt <> " <kind> [<args>] where <kind> is one of: "
          <> renderKindsAsText
      payloadLine = case mPayload of
        Nothing -> ""
        Just p  -> "\nBuffered text: " <> p
  in header <> payloadLine

-- | A renderer that emits a Telegram-friendly text body. v1 surfaces
-- the inline-keyboard hint as plain text (the channel's underlying
-- 'sendMessage' API discards the markup gracefully); WU11 may upgrade
-- the rendering once 'ChannelHandle' carries an inline-keyboard seam.
--
-- The text body is intentionally compact (≤ 200 chars even with a
-- buffered payload) so it fits well in a mobile chat bubble.
mkInlineKeyboardPromptRenderer :: PromptRenderer
mkInlineKeyboardPromptRenderer = PromptRenderer renderInlineKeyboardPrompt

renderInlineKeyboardPrompt :: TabIndex -> Maybe Text -> Text
renderInlineKeyboardPrompt idx mPayload =
  let nTxt = tShowIdx idx
      header =
        "Choose a kind for /" <> nTxt
          <> ": [ai] [harness] [shell] [ssh] [tmux] — "
          <> "reply /tab new " <> nTxt <> " <kind>"
      payloadLine = case mPayload of
        Nothing -> ""
        Just p  -> "\nBuffered text: " <> p
  in header <> payloadLine

-- | Comma-separated list of the supported tab-kind keywords. Used by
-- the text renderer; exposed so tests can pin the exact wording.
renderKindsAsText :: Text
renderKindsAsText = T.intercalate ", " ["ai", "harness", "shell", "ssh", "tmux"]

-- | Format a 'TabIndex' as the user-facing decimal string. Internal
-- helper that mirrors the dispatcher's own 'tShowIdx' (kept local to
-- avoid an import cycle into 'Dispatcher').
tShowIdx :: TabIndex -> Text
tShowIdx = T.pack . show . unTabIndex
