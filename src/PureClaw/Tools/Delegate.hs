module PureClaw.Tools.Delegate
  ( -- * Tool registration
    delegateTaskTool
    -- * Reusable sub-agent engine
  , runSubAgent
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Core.Types
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a delegate_task tool that spawns an isolated sub-agent
-- to complete a goal. The sub-agent runs with a restricted toolset
-- (optionally filtered), a bounded turn count, and returns a summary
-- of its work.
--
-- The sub-agent uses the same provider and model as the parent but
-- gets its own context (no conversation history leakage). It cannot
-- access the parent's session, vault, or harnesses.
delegateTaskTool :: AgentEnv -> (ToolDefinition, ToolHandler)
delegateTaskTool parentEnv = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "delegate_task"
      , _td_description = T.unlines
          [ "Spawn an isolated sub-agent to complete a focused task."
          , "The sub-agent has its own context (no conversation history leakage)"
          , "and a restricted toolset. It runs for up to max_turns (default: 10)"
          , "and returns a summary of its work."
          , "Use for: parallel subtasks, research, code generation, analysis."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "goal" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("What the sub-agent should accomplish" :: Text)
                  ]
              , "context" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Additional context to include in the sub-agent's system prompt" :: Text)
                  ]
              , "tools" .= object
                  [ "type" .= ("array" :: Text)
                  , "items" .= object ["type" .= ("string" :: Text)]
                  , "description" .= ("Restrict sub-agent to these tool names (default: all parent tools except delegate_task)" :: Text)
                  ]
              , "max_turns" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Maximum conversation turns (default: 10, max: 30)" :: Text)
                  ]
              ]
          , "required" .= (["goal"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseDelegateInput input of
        Left err -> pure (T.pack err, True)
        Right di -> runDelegate di

    runDelegate :: DelegateInput -> IO (Text, Bool)
    runDelegate di = do
      -- Check provider is available
      mProvider <- readIORef (_env_provider parentEnv)
      case mProvider of
        Nothing -> pure ("Cannot delegate: no provider configured", True)
        Just provider -> do
          mModel <- readIORef (_env_model parentEnv)
          case mModel of
            Nothing -> pure ("Cannot delegate: no model configured", True)
            Just model -> do
              let maxTurns = min 30 (fromMaybe 10 (_di_maxTurns di))
                  subRegistry = buildSubRegistry (_di_tools di)
                  sysPrompt = buildSubSystemPrompt (_di_goal di) (_di_context di)
              result <- try @SomeException $
                runSubAgent provider model subRegistry sysPrompt (_di_goal di) maxTurns
              case result of
                Left e -> pure ("delegate_task error: " <> T.pack (show e), True)
                Right output -> pure (output, False)

    buildSubRegistry :: Maybe [Text] -> ToolRegistry
    buildSubRegistry Nothing =
      -- All parent tools except delegate_task (prevent recursive delegation)
      filterRegistry (/= "delegate_task") (_env_registry parentEnv)
    buildSubRegistry (Just names) =
      filterRegistry (\n -> n `elem` names && n /= "delegate_task") (_env_registry parentEnv)

    buildSubSystemPrompt :: Text -> Maybe Text -> Maybe Text
    buildSubSystemPrompt goal mContext =
      Just $ T.unlines $ filter (not . T.null)
        [ "You are a focused sub-agent. Complete the following task and report your results concisely."
        , ""
        , "TASK: " <> goal
        , maybe "" ("\nCONTEXT: " <>) mContext
        , ""
        , "When you have completed the task, provide a clear summary of what you did and the results."
        , "Do not ask clarifying questions — work with what you have."
        ]

-- | Run a bounded sub-agent conversation.
-- Returns the final assistant response text.
runSubAgent
  :: SomeProvider
  -> ModelId
  -> ToolRegistry
  -> Maybe Text
  -> Text
  -> Int
  -> IO Text
runSubAgent provider model registry sysPrompt goal maxTurns = do
  let ctx0 = addMessage (textMessage User goal) (emptyContext sysPrompt)
      tools = registryDefinitions registry
  go ctx0 tools maxTurns
  where
    go _ctx _tools 0 = pure "[Sub-agent reached maximum turn limit]"
    go ctx tools turnsLeft = do
      let req = CompletionRequest
            { _cr_model        = model
            , _cr_messages     = contextMessages ctx
            , _cr_systemPrompt = contextSystemPrompt ctx
            , _cr_maxTokens    = Just 4096
            , _cr_tools        = tools
            , _cr_toolChoice   = Nothing
            }
      resp <- complete provider req
      let calls = toolUseCalls resp
          text = responseText resp
          ctx' = addMessage (Message Assistant (_crsp_content resp)) ctx
      if null calls
        then pure text  -- Sub-agent is done
        else do
          -- Execute tool calls
          results <- mapM (executeSubCall registry) calls
          let resultMsg = toolResultMessage results
              ctx'' = addMessage resultMsg ctx'
          go ctx'' tools (turnsLeft - 1)

    executeSubCall :: ToolRegistry -> (ToolCallId, Text, Value) -> IO (ToolCallId, [ToolResultPart], Bool)
    executeSubCall reg (callId, name, input) = do
      result <- executeTool reg name input
      case result of
        Nothing -> pure (callId, [TRPText ("Unknown tool: " <> name)], True)
        Just (parts, isErr) -> pure (callId, parts, isErr)

data DelegateInput = DelegateInput
  { _di_goal     :: Text
  , _di_context  :: Maybe Text
  , _di_tools    :: Maybe [Text]
  , _di_maxTurns :: Maybe Int
  }

parseDelegateInput :: Value -> Parser DelegateInput
parseDelegateInput = withObject "DelegateInput" $ \o ->
  DelegateInput
    <$> o .:  "goal"
    <*> o .:? "context"
    <*> o .:? "tools"
    <*> o .:? "max_turns"
