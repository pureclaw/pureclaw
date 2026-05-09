module PureClaw.Tools.ExecuteCode
  ( -- * Tool registration
    executeCodeTool
  ) where

import Control.Concurrent.Async qualified as Async
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit
import System.Process.Typed qualified as P
import System.Timeout qualified as Timeout

import PureClaw.Providers.Class
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Tools.Registry

-- | Create an execute_code tool that runs Python (or other language)
-- code in a subprocess. The interpreter must be allowed by the
-- security policy. Output is capped at 50KB stdout / 10KB stderr.
executeCodeTool :: SecurityPolicy -> (ToolDefinition, ToolHandler)
executeCodeTool policy = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "execute_code"
      , _td_description = T.unlines
          [ "Execute code in a subprocess. The interpreter (python3, node, etc.)"
          , "must be allowed by the security policy."
          , "Code is passed via stdin. Output is capped at 50KB stdout / 10KB stderr."
          , "Default timeout: 30 seconds (configurable up to 300s)."
          ]
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "code" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The code to execute" :: Text)
                  ]
              , "language" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("Language/interpreter: python3, node, ruby, bash (default: python3)" :: Text)
                  ]
              , "timeout" .= object
                  [ "type" .= ("integer" :: Text)
                  , "description" .= ("Timeout in seconds (default: 30, max: 300)" :: Text)
                  ]
              ]
          , "required" .= (["code"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseCodeInput input of
        Left err -> pure (T.pack err, True)
        Right ci -> runCode ci

    runCode :: CodeInput -> IO (Text, Bool)
    runCode ci = do
      let interpreter = resolveInterpreter (_ci_language ci)
          timeoutSec = min 300 (fromMaybe 30 (_ci_timeout ci))
      case authorize policy (T.unpack interpreter) ["-"] of
        Left (CommandNotAllowed _) ->
          pure ("Interpreter not allowed: " <> interpreter
               <> ". Add it to --allow or set --autonomy full.", True)
        Left CommandInAutonomyDeny ->
          pure ("All commands denied by security policy", True)
        Right _authorized -> do
          let config = P.setStdin (P.byteStringInput (BL.fromStrict (TE.encodeUtf8 (_ci_code ci))))
                     $ P.setEnv safeEnv
                     $ P.proc (T.unpack interpreter) ["-"]
          worker <- Async.async $ P.readProcess config
          result <- Timeout.timeout (timeoutSec * 1000000) (Async.wait worker)
          case result of
            Nothing -> do
              Async.cancel worker
              pure ("Code execution timed out after " <> T.pack (show timeoutSec) <> "s", True)
            Just (exitCode, outLazy, errLazy) ->
              let outBs = BL.toStrict outLazy
                  errBs = BL.toStrict errLazy
                  out = truncateOutput 51200 (TE.decodeUtf8Lenient outBs)
                  err = truncateOutput 10240 (TE.decodeUtf8Lenient errBs)
                  exitInfo = case exitCode of
                    ExitSuccess   -> ""
                    ExitFailure n -> "\nExit code: " <> T.pack (show n)
                  parts = filter (not . T.null) [out, err, exitInfo]
                  combined = T.strip (T.intercalate "\n" parts)
              in pure (if T.null combined then "(no output)" else combined,
                       exitCode /= ExitSuccess)

    resolveInterpreter :: Maybe Text -> Text
    resolveInterpreter Nothing          = "python3"
    resolveInterpreter (Just "python")  = "python3"
    resolveInterpreter (Just "python3") = "python3"
    resolveInterpreter (Just "node")    = "node"
    resolveInterpreter (Just "ruby")    = "ruby"
    resolveInterpreter (Just "bash")    = "bash"
    resolveInterpreter (Just "sh")      = "sh"
    resolveInterpreter (Just other)     = other

    truncateOutput :: Int -> Text -> Text
    truncateOutput maxLen t
      | T.length t <= maxLen = t
      | otherwise = T.take maxLen t <> "\n[...truncated at " <> T.pack (show maxLen) <> " chars]"

-- | Minimal safe environment for subprocesses.
safeEnv :: [(String, String)]
safeEnv = [("PATH", "/usr/bin:/bin:/usr/local/bin")]

data CodeInput = CodeInput
  { _ci_code     :: Text
  , _ci_language :: Maybe Text
  , _ci_timeout  :: Maybe Int
  }

parseCodeInput :: Value -> Parser CodeInput
parseCodeInput = withObject "CodeInput" $ \o ->
  CodeInput
    <$> o .:  "code"
    <*> o .:? "language"
    <*> o .:? "timeout"
