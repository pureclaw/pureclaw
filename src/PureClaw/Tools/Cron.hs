module PureClaw.Tools.Cron
  ( -- * Tool registration
    cronTool
    -- * Scheduler handle
  , CronHandle (..)
  , mkCronHandle
  , mkNoOpCronHandle
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Scheduler.Cron
import PureClaw.Tools.Registry

-- | Handle for managing the cron scheduler. Wraps an IORef-based
-- scheduler with operations the agent can call.
data CronHandle = CronHandle
  { _crh_add    :: Text -> CronExpr -> IO () -> IO Bool
  , _crh_remove :: Text -> IO Bool
  , _crh_list   :: IO [(Text, Text)]  -- ^ (name, cron expression as text)
  }

-- | Create a real cron handle backed by an IORef scheduler.
mkCronHandle :: IORef CronScheduler -> CronHandle
mkCronHandle ref = CronHandle
  { _crh_add = \name expr action -> do
      let job = CronJob { _cj_name = name, _cj_expr = expr, _cj_action = action }
      atomicModifyIORef' ref $ \sched -> (addJob job sched, ())
      pure True
  , _crh_remove = \name ->
      atomicModifyIORef' ref $ \sched ->
        let before = length (schedulerJobNames sched)
            sched' = removeJob name sched
            after = length (schedulerJobNames sched')
        in (sched', before /= after)
  , _crh_list = do
      sched <- readIORef ref
      pure [(name, formatCronExpr expr)
           | (name, expr) <- schedulerJobNames sched]
  }

-- | No-op cron handle for testing.
mkNoOpCronHandle :: CronHandle
mkNoOpCronHandle = CronHandle
  { _crh_add    = \_ _ _ -> pure True
  , _crh_remove = \_ -> pure True
  , _crh_list   = pure []
  }

-- | Create a cron tool for agent-managed scheduled jobs.
-- When the agent adds a cron job, the action sends a message to the
-- channel with the job name (for cron result delivery).
cronTool :: ChannelHandle -> CronHandle -> (ToolDefinition, ToolHandler)
cronTool ch crh = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "cron"
      , _td_description = "Manage scheduled cron jobs. Actions: add (create a job), remove (delete a job), list (show all jobs)."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "action" .= object
                  [ "type" .= ("string" :: Text)
                  , "enum" .= (["add", "remove", "list"] :: [Text])
                  , "description" .= ("The action to perform" :: Text)
                  ]
              , "name" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Job name (for add, remove)" :: Text)
                  ]
              , "schedule" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Cron expression, e.g. '*/5 * * * *' (for add)" :: Text)
                  ]
              , "message" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Message to send when job fires (for add)" :: Text)
                  ]
              ]
          , "required" .= (["action"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseAction input of
        Left err -> pure (T.pack err, True)
        Right action -> dispatch action input

    dispatch :: Text -> Value -> IO (Text, Bool)
    dispatch "add" input =
      case parseEither parseAdd input of
        Left err -> pure (T.pack err, True)
        Right (name, schedule, message) ->
          case parseCronExpr schedule of
            Left err -> pure ("Invalid cron expression: " <> T.pack err, True)
            Right expr -> do
              let action = _ch_send ch (OutgoingMessage ("[cron:" <> name <> "] " <> message))
              result <- try @SomeException (_crh_add crh name expr action)
              case result of
                Left e -> pure (T.pack (show e), True)
                Right True -> pure ("Added cron job: " <> name <> " (" <> schedule <> ")", False)
                Right False -> pure ("Failed to add job: " <> name, True)
    dispatch "remove" input =
      case parseEither parseName input of
        Left err -> pure (T.pack err, True)
        Right name -> do
          result <- _crh_remove crh name
          if result
            then pure ("Removed cron job: " <> name, False)
            else pure ("Job not found: " <> name, True)
    dispatch "list" _ = do
      jobs <- _crh_list crh
      if null jobs
        then pure ("No cron jobs scheduled", False)
        else pure (T.intercalate "\n" [name <> " — " <> expr | (name, expr) <- jobs], False)
    dispatch action _ = pure ("Unknown action: " <> action, True)

    parseAction :: Value -> Parser Text
    parseAction = withObject "CronInput" $ \o -> o .: "action"

    parseAdd :: Value -> Parser (Text, Text, Text)
    parseAdd = withObject "CronAddInput" $ \o ->
      (,,) <$> o .: "name" <*> o .: "schedule" <*> o .: "message"

    parseName :: Value -> Parser Text
    parseName = withObject "CronNameInput" $ \o -> o .: "name"

-- | Format a CronExpr back to its text representation.
formatCronExpr :: CronExpr -> Text
formatCronExpr expr = T.intercalate " "
  [ formatField (_ce_minute expr)
  , formatField (_ce_hour expr)
  , formatField (_ce_dayOfMonth expr)
  , formatField (_ce_month expr)
  , formatField (_ce_dayOfWeek expr)
  ]

-- | Format a CronField to text.
formatField :: CronField -> Text
formatField Wildcard = "*"
formatField (Exact n) = T.pack (show n)
formatField (Range lo hi) = T.pack (show lo) <> "-" <> T.pack (show hi)
formatField (Step base n) = formatField base <> "/" <> T.pack (show n)
formatField (ListField fs) = T.intercalate "," (map formatField fs)
