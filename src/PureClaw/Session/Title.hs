-- | Canonical displayed title for a session — the single source of truth
-- shared by both the web frontend and the TUI so the two compute a
-- session's name identically.
--
-- This module is a leaf: it depends only on the serializable session and
-- transcript types ('PureClaw.Session.Types', 'PureClaw.Transcript.Types')
-- and must NOT import "PureClaw.Frontend.API" (which would create a cycle).
module PureClaw.Session.Title
  ( sessionTitle
  , firstMessageSnippet
  , snippetCharBudget
  ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import System.FilePath ((</>))
import System.IO (IOMode (..), withFile)

import PureClaw.Agent.AgentDef (unAgentName)
import PureClaw.Core.Types (unSessionId)
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Transcript.Types (Direction (..), TranscriptEntry (..))

-- | Canonical displayed title: override -> model summary -> first-message
-- snippet -> agent -> session-id prefix. The single source of truth for web
-- AND TUI so defaults are identical.
sessionTitle :: FilePath -> SessionMeta -> IO Text
sessionTitle baseDir meta =
  case _sm_description meta of
    Just d | not (T.null (T.strip d)) -> pure d
    _ -> case _sm_autoSummary meta of
      Just s | not (T.null (T.strip s)) -> pure s
      _ -> do
        mSnip <- firstMessageSnippet baseDir meta
        pure $ case mSnip of
          Just s | not (T.null s) -> s
          _ -> fallbackLabel meta

-- | Last-resort label when there is no description, summary, or
-- first-message snippet: the agent name, else a prefix of the session id.
fallbackLabel :: SessionMeta -> Text
fallbackLabel meta = case _sm_agent meta of
  Just a  -> unAgentName a
  Nothing -> T.take 12 (unSessionId (_sm_id meta))

-- | Cheap fallback for display: read just the first line of the
-- session's @transcript.jsonl@, decode it as a 'TranscriptEntry', and
-- extract a short snippet of the first user message. Returns 'Nothing'
-- when there's no transcript, the first entry isn't a request, or any
-- decoding step fails. The returned string is at most
-- 'snippetCharBudget' chars with newlines normalised to spaces.
--
-- Cost is one bounded read per call (we don't load the whole transcript).
firstMessageSnippet :: FilePath -> SessionMeta -> IO (Maybe Text)
firstMessageSnippet baseDir meta = do
  let path = baseDir </> T.unpack (unSessionId (_sm_id meta)) </> "transcript.jsonl"
  result <- try @IOException $ withFile path ReadMode BSC.hGetLine
  case result of
    Left _    -> pure Nothing
    Right line -> case Aeson.eitherDecodeStrict' line :: Either String TranscriptEntry of
      Left _ -> pure Nothing
      Right entry
        | _te_direction entry /= Request -> pure Nothing
        | otherwise -> pure (snippetFromPayload (_te_payload entry))

snippetCharBudget :: Int
snippetCharBudget = 120

-- | Extract a display snippet from a request payload. Two shapes:
-- (1) JSON object with a "messages" array (provider request) — pull
--     text out of the first message; (2) plain text (harness send) —
--     use the payload directly. Trimmed, newline-normalised, and
--     truncated to 'snippetCharBudget' characters.
snippetFromPayload :: Text -> Maybe Text
snippetFromPayload raw = trimAndTruncate <$>
  case Aeson.decodeStrict (TE.encodeUtf8 raw) of
    Just (Aeson.Object o)
      | Just (Aeson.Array msgs) <- KM.lookup "messages" o
      , not (V.null msgs)
      -> messageText (V.unsafeHead msgs)
    _ -> Just raw
  where
    -- Anthropic-style message content: either a plain string or an
    -- array of {type:"text", text:"..."} blocks. We just want a
    -- human-readable lead.
    messageText :: Aeson.Value -> Maybe Text
    messageText (Aeson.Object m) = case KM.lookup "content" m of
      Just (Aeson.String s) -> Just s
      Just (Aeson.Array bs) -> Just (T.intercalate " " [t | Aeson.Object b <- V.toList bs
                                                          , Just (Aeson.String t) <- [KM.lookup "text" b]])
      _                     -> Nothing
    messageText _ = Nothing

    trimAndTruncate :: Text -> Text
    trimAndTruncate t =
      let normalized = T.unwords (T.words t)  -- collapse whitespace incl. newlines
      in  if T.length normalized > snippetCharBudget
            then T.take (snippetCharBudget - 1) normalized <> "\x2026"
            else normalized
