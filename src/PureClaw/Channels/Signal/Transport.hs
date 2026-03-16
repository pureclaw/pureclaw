module PureClaw.Channels.Signal.Transport
  ( -- * Transport handle (testability seam for signal-cli)
    SignalTransport (..)
    -- * Real implementation
  , mkSignalCliTransport
    -- * Mock implementation (for tests)
  , mkMockSignalTransport
    -- * Message chunking
  , chunkMessage
  ) where

import Control.Concurrent.STM
import Data.Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import System.IO
import System.Process.Typed qualified as P

import PureClaw.Handles.Log

-- | Transport abstraction over signal-cli. The real implementation spawns
-- signal-cli as a child process and communicates via JSON-RPC over stdio.
-- The mock implementation uses in-memory queues for testing.
data SignalTransport = SignalTransport
  { _st_receive :: IO Value
    -- ^ Block until a JSON-RPC message arrives from signal-cli
  , _st_send    :: Text -> Text -> IO ()
    -- ^ Send a message: recipient (E.164) -> body -> IO ()
  , _st_close   :: IO ()
    -- ^ Shut down the transport (kill signal-cli, close handles)
  }

-- | Create a real transport that spawns @signal-cli jsonRpc@ as a child process.
-- The process runs for the lifetime of the transport. Call '_st_close' to shut down.
mkSignalCliTransport :: Text -> LogHandle -> IO SignalTransport
mkSignalCliTransport account logger = do
  let config = P.setStdin P.createPipe
             $ P.setStdout P.createPipe
             $ P.setStderr P.inherit
             $ P.proc "signal-cli"
                 [ "--output=json"
                 , "--trust-new-identities=always"
                 , "-u", T.unpack account
                 , "jsonRpc"
                 ]
  process <- P.startProcess config
  let stdinH  = P.getStdin process
      stdoutH = P.getStdout process
  hSetBuffering stdinH LineBuffering
  hSetBuffering stdoutH LineBuffering
  _lh_logInfo logger $ "signal-cli started for account " <> account
  let recvLoop = do
        line <- BS8.hGetLine stdoutH
        case eitherDecode (BL.fromStrict line) of
          Left err -> do
            _lh_logWarn logger $ "signal-cli parse error: " <> T.pack err
            recvLoop  -- Skip unparseable lines and try again
          Right val -> pure val
  pure SignalTransport
    { _st_receive = recvLoop
    , _st_send = \recipient body -> do
        let rpcMsg = object
              [ "jsonrpc" .= ("2.0" :: Text)
              , "method"  .= ("send" :: Text)
              , "params"  .= object
                  [ "recipient" .= [recipient]
                  , "message"   .= body
                  ]
              ]
        BL.hPut stdinH (encode rpcMsg <> "\n")
        hFlush stdinH
    , _st_close = do
        _lh_logInfo logger "Stopping signal-cli..."
        P.stopProcess process
    }

-- | Create a mock transport backed by in-memory queues. Used in tests.
mkMockSignalTransport
  :: TQueue Value         -- ^ Incoming messages (simulates signal-cli stdout)
  -> TQueue (Text, Text)  -- ^ Outgoing messages (recipient, body) for assertions
  -> SignalTransport
mkMockSignalTransport inQueue outQueue = SignalTransport
  { _st_receive = atomically $ readTQueue inQueue
  , _st_send    = \recipient body ->
      atomically $ writeTQueue outQueue (recipient, body)
  , _st_close   = pure ()
  }

-- | Split a long message into chunks that fit within a character limit,
-- breaking on paragraph boundaries (double newline) where possible.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit text
  | T.length text <= limit = [text]
  | otherwise = go text
  where
    go remaining
      | T.null remaining = []
      | T.length remaining <= limit = [remaining]
      | otherwise =
          let candidate = T.take limit remaining
              -- Try to break at a paragraph boundary
              breakPoint = case T.breakOnAll "\n\n" candidate of
                [] -> case T.breakOnAll "\n" candidate of
                  [] -> limit  -- no good break point, hard cut
                  breaks -> T.length (fst (last breaks)) + 1
                breaks -> T.length (fst (last breaks)) + 2
              (chunk, rest) = T.splitAt breakPoint remaining
          in T.stripEnd chunk : go (T.stripStart rest)
