-- |
-- Module      : PureClaw.Internal.Redact (hs-boot)
--
-- Breaks the circular import between 'PureClaw.Internal.Redact'
-- (which pattern-matches on 'PureClaw.Handles.Backend.BackendError' and
-- 'BackendException') and 'PureClaw.Handles.Backend' (whose hand-written
-- 'Show' instances delegate to the redactors).
--
-- Only the credential prompt scrubber is exposed here. The
-- 'redactBackendError' \/ 'redactBackendException' functions are NOT
-- in the boot: their callers (the 'Show' instances) need only inline
-- 'show'-style usage which the boot cannot supply because it cannot
-- name the @Handles.Backend@ types without re-introducing the cycle.
-- Instead, the 'Show' instances render via a generic 'String' bridge
-- (see 'redactedShowString' below).
module PureClaw.Internal.Redact where

import Data.ByteString (ByteString)
import Data.Text (Text)

credentialPromptScrubber :: ByteString -> ByteString

-- | Generic redaction-safe Show bridge: run a 'String' through the
-- 'redactErr' text pipeline. Avoids the cycle by accepting an
-- already-stringified payload — the caller in @Handles.Backend@
-- composes 'show' on the inner ADT first.
redactedShowString :: String -> Text
