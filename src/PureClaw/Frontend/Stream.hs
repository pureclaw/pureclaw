-- | WS-streaming endpoint placeholder. The full implementation lands in WU3
-- (see @.beads/plans/active-plan.md@). This stub exists so WU0 can verify
-- that @wai-websockets@ is reachable in the build environment.
module PureClaw.Frontend.Stream
  ( wu0SmokeTest
  ) where

import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Network.Wai (Application)

-- | Inert reference to @websocketsOr@ so the import is non-vacuous and the
-- compiler will refuse to drop the dependency. Replaced by 'streamApp' in WU3.
wu0SmokeTest :: Application -> Application
wu0SmokeTest = WaiWS.websocketsOr WS.defaultConnectionOptions stubServerApp
  where
    -- WS server-app: rejects every pending connection. WU3 replaces this
    -- with the real handler.
    stubServerApp :: WS.PendingConnection -> IO ()
    stubServerApp pending = WS.rejectRequest pending "Stream.hs is a WU0 stub"
