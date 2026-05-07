{-# LANGUAGE DisambiguateRecordFields #-}
module PureClaw.MCP
  ( -- * Server state
    McpServer (..)
    -- * Lifecycle
  , connectServer
  , disconnectServer
    -- * Tool queries
  , mcpToolNames
    -- * Registry integration
  , mcpRegistry
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, catch, throwIO, try)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (Handle, hClose, hFlush, hIsEOF, hSetBuffering, BufferMode (..))
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , cleanupProcess
  , createProcess
  , waitForProcess
  )
import System.Timeout (timeout)

import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL

import MCP.Client.API qualified as MCP
import MCP.Client.Config (ClientConfig (..), defaultClientConfig)
import MCP.Client.Error (MCPClientError)
import MCP.Client.Session (ClientSession, withClientSession, initialize)
import MCP.Client.Transport (Transport (..))
import MCP.Protocol (CallToolResult (..), InitializeResult (..), ListToolsResult (..))
import MCP.Types
  ( ContentBlock (..)
  , ImageContent (..)
  , Implementation
  , TextContent (..)
  , Tool (..)
  )

import PureClaw.Handles.Log
import PureClaw.Providers.Class (ToolDefinition (..), ToolResultPart (..))
import PureClaw.Tools.Registry

-- | An active MCP server connection.
data McpServer = McpServer
  { _ms_name       :: Text
    -- ^ User-assigned name for this server (e.g. "filesystem", "time")
  , _ms_command    :: [Text]
    -- ^ The command + args used to spawn the server (for display)
  , _ms_session    :: ClientSession
    -- ^ Active MCP client session
  , _ms_tools      :: [Tool]
    -- ^ Tools discovered during initialization
  , _ms_serverInfo :: Maybe Implementation
    -- ^ Server identity from initialization
  , _ms_cleanup    :: IO ()
    -- ^ Shuts down the process and background threads
  }

-- | Connect to an MCP server by spawning it as a child process.
--
-- The server process communicates over stdio (JSON-RPC). On success,
-- returns the connected server with its discovered tools. On failure,
-- throws 'MCPClientError' or 'IOException'.
connectServer :: LogHandle -> Text -> [Text] -> CreateProcess -> IO McpServer
connectServer logger serverName cmdArgs cp = do
  _lh_logInfo logger $ "MCP: connecting to " <> serverName <> "..."

  -- Spawn the child process
  let cp' = cp { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }
  (Just hIn, Just hOut, _hErr, ph) <- createProcess cp'
  hSetBuffering hIn LineBuffering
  hSetBuffering hOut LineBuffering

  let transport = mkStdioTransport hIn hOut ph

  -- Start a client session (spawns background receive thread).
  -- We manage the session manually rather than using withClientSession's
  -- bracket because the connection persists across slash commands.
  sessionMVar <- newEmptyMVar
  tidRef <- newIORef Nothing
  tid <- forkIO $
    withClientSession transport
      defaultClientConfig { config_request_timeout_us = 30_000_000 }
      (\session -> do
        putMVar sessionMVar (Right session)
        -- Block forever until the thread is killed
        newEmptyMVar >>= takeMVar :: IO ()
      )
    `catch` \(e :: SomeException) ->
      putMVar sessionMVar (Left e)
  writeIORef tidRef (Just tid)

  result <- takeMVar sessionMVar
  session <- case result of
    Left e  -> do
      stopProcess hIn hOut ph
      throwIO e
    Right s -> pure s

  -- Initialize the MCP protocol
  initResult <- initialize session
    `catch` \(e :: MCPClientError) -> do
      readIORef tidRef >>= mapM_ killThread
      stopProcess hIn hOut ph
      throwIO e

  let sInfo = Just (serverInfo initResult)

  -- Discover available tools
  ListToolsResult { tools = mcpTools } <- MCP.listTools session Nothing

  _lh_logInfo logger $ "MCP: " <> serverName <> " connected ("
    <> T.pack (show (length mcpTools)) <> " tools)"

  let cleanup = do
        readIORef tidRef >>= mapM_ killThread
        stopProcess hIn hOut ph

  pure McpServer
    { _ms_name       = serverName
    , _ms_command    = cmdArgs
    , _ms_session    = session
    , _ms_tools      = mcpTools
    , _ms_serverInfo = sInfo
    , _ms_cleanup    = cleanup
    }

-- | Disconnect from an MCP server, cleaning up the child process.
disconnectServer :: LogHandle -> McpServer -> IO ()
disconnectServer logger server = do
  _lh_logInfo logger $ "MCP: disconnecting " <> _ms_name server
  _ms_cleanup server
    `catch` \(_ :: SomeException) -> pure ()

-- | Get the names of all tools provided by an MCP server.
mcpToolNames :: McpServer -> [Text]
mcpToolNames = map toolName . _ms_tools

-- | Build a 'ToolRegistry' from a list of connected MCP servers.
--
-- Each MCP tool is registered with its original name. If multiple
-- servers expose tools with the same name, the last server wins.
mcpRegistry :: [McpServer] -> ToolRegistry
mcpRegistry = foldl addServer emptyRegistry
  where
    addServer :: ToolRegistry -> McpServer -> ToolRegistry
    addServer reg server =
      foldl (addTool server) reg (_ms_tools server)

    addTool :: McpServer -> ToolRegistry -> Tool -> ToolRegistry
    addTool server reg tool =
      let toolN = toolName tool
          def = ToolDefinition
            { _td_name        = toolN
            , _td_description = toolDesc tool
            , _td_inputSchema = Aeson.toJSON (inputSchema tool)
            }
          handler input = mcpExecuteTool (_ms_session server) toolN input
      in registerRichTool def handler reg

-- ---------------------------------------------------------------------------
-- Tool accessors (avoid DuplicateRecordFields ambiguity)
-- ---------------------------------------------------------------------------

toolName :: Tool -> Text
toolName (Tool { name = n }) = n

toolDesc :: Tool -> Text
toolDesc (Tool { description = d }) = maybe "" id d

-- ---------------------------------------------------------------------------
-- Tool execution
-- ---------------------------------------------------------------------------

-- | Execute an MCP tool call, returning PureClaw-compatible results.
mcpExecuteTool :: ClientSession -> Text -> Value -> IO ([ToolResultPart], Bool)
mcpExecuteTool session tName input = do
  let argsMap = keyMapToMap input
  result <- try @MCPClientError $ MCP.callTool session tName argsMap
  case result of
    Left e -> pure ([TRPText (T.pack (show e))], True)
    Right (CallToolResult { content = blocks, isError = mErr }) ->
      let isErr = maybe False id mErr
          parts = map convertContent blocks
      in pure (if null parts then [TRPText ""] else parts, isErr)

convertContent :: ContentBlock -> ToolResultPart
convertContent (TextBlock (TextContent { text = t })) = TRPText t
convertContent (ImageBlock (ImageContent { data' = d, mimeType = m })) =
  TRPImage m (BS.pack (T.unpack d))
convertContent _ = TRPText "[unsupported content type]"

-- | Convert a JSON object to @Maybe (Map Text Value)@ for callTool.
keyMapToMap :: Value -> Maybe (Map.Map Text Value)
keyMapToMap (Object km) = Just $ Map.fromList
  [(Key.toText k, v) | (k, v) <- KM.toList km]
keyMapToMap _ = Nothing

-- ---------------------------------------------------------------------------
-- Internal: stdio transport (manual lifecycle, not bracket-based)
-- ---------------------------------------------------------------------------

mkStdioTransport :: Handle -> Handle -> ProcessHandle -> Transport
mkStdioTransport hIn hOut ph = Transport
  { transport_send = \msg -> do
      BSL.hPut hIn (Aeson.encode msg)
      BSL.hPut hIn "\n"
      hFlush hIn
  , transport_receive = do
      eof <- hIsEOF hOut
      if eof
        then pure Nothing
        else do
          line <- BS.hGetLine hOut
          case Aeson.eitherDecodeStrict' line of
            Right msg -> pure (Just msg)
            Left _    -> transport_receive (mkStdioTransport hIn hOut ph)
  , transport_close = stopProcess hIn hOut ph
  }

stopProcess :: Handle -> Handle -> ProcessHandle -> IO ()
stopProcess hIn hOut ph = do
  hClose hIn `catch` \(_ :: SomeException) -> pure ()
  exited <- timeout 2_000_000 (waitForProcess ph)
  case exited of
    Just _  -> hClose hOut `catch` \(_ :: SomeException) -> pure ()
    Nothing -> cleanupProcess (Nothing, Just hOut, Nothing, ph)
