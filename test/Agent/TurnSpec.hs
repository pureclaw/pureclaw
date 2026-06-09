{-# LANGUAGE OverloadedStrings #-}

-- | Tests for 'PureClaw.Agent.Turn' (Tabs-as-View stage 8b.2).
--
-- 'runTurnWithTools' is the env-light extraction of @Loop.handleCompletion@:
-- it runs one user turn WITH the tool-call cycle, streaming to an injected
-- sink ('TurnEvent') and appending to an injected transcript, returning the
-- updated 'Context'. Every dependency is faked here — no real provider, no
-- real tool registry.
module Agent.TurnSpec (spec) where

import Control.Exception qualified as E
import Control.Monad qualified as M
import Data.Aeson qualified as Aeson
import Data.IORef qualified as Ref
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE

import Test.Hspec

import PureClaw.Agent.Context qualified as Ctx
import PureClaw.Agent.Turn
import PureClaw.Core.Types (ModelId (..), ToolCallId (..))
import PureClaw.Providers.Class qualified as P

-- ---------------------------------------------------------------------------
-- Fakes & helpers
-- ---------------------------------------------------------------------------

-- | A canned response with the given content blocks and no usage.
mkResp :: [P.ContentBlock] -> P.CompletionResponse
mkResp blocks = P.CompletionResponse
  { P._crsp_content = blocks
  , P._crsp_model   = ModelId "fake-model"
  , P._crsp_usage   = Nothing
  }

-- | A fake stream fn that, per call, pops the next scripted action list and
-- replays each 'P.StreamEvent' to the callback. The IORef holds a list of
-- "scripts" — one per expected completion call.
scriptedStream
  :: Ref.IORef [[P.StreamEvent]]
  -> (P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ())
scriptedStream scriptsRef _req cb = do
  scripts <- Ref.readIORef scriptsRef
  case scripts of
    []           -> pure ()  -- no more scripts: emit nothing
    (evs : rest) -> do
      Ref.writeIORef scriptsRef rest
      M.forM_ evs cb

-- | A recording emit sink that appends every 'TurnEvent' to an IORef.
recordingEmit :: Ref.IORef [TurnEvent] -> (TurnEvent -> IO ())
recordingEmit ref ev = Ref.modifyIORef' ref (++ [ev])

-- | A recording transcript that appends every 'P.Message' to an IORef.
recordingRecord :: Ref.IORef [P.Message] -> (P.Message -> IO ())
recordingRecord ref m = Ref.modifyIORef' ref (++ [m])

-- | A monotonic StreamId allocator backed by an IORef counter.
-- 'StreamId'\/'mkStreamId' are re-exported through 'PureClaw.Agent.Turn'.
nextSid :: Ref.IORef Word -> IO StreamId
nextSid ref = do
  n <- Ref.readIORef ref
  Ref.writeIORef ref (n + 1)
  pure (mkStreamId (fromIntegral n))

-- | A tool-exec fn that records (callId, name) and returns a fixed
-- tool-result message echoing the call id.
recordingExec
  :: Ref.IORef [(ToolCallId, Text)]
  -> (ToolCallId -> Text -> Aeson.Value -> IO P.Message)
recordingExec ref callId name input = do
  -- Force the JSON input argument so its expression box is exercised; the
  -- encoded form is folded into the result text.
  let inputTxt = TL.toStrict (TLE.decodeUtf8 (Aeson.encode input))
  Ref.modifyIORef' ref (++ [(callId, name)])
  pure (P.toolResultMessage
          [(callId, [P.TRPText ("result:" <> unToolCallId callId <> ":" <> inputTxt)], False)])

-- | Build a 'TurnDeps' from injected pieces with sensible defaults.
mkDeps
  :: (P.CompletionRequest -> (P.StreamEvent -> IO ()) -> IO ())
  -> (ToolCallId -> Text -> Aeson.Value -> IO P.Message)
  -> (TurnEvent -> IO ())
  -> (P.Message -> IO ())
  -> IO StreamId
  -> TurnDeps
mkDeps stream execTool emit record next = TurnDeps
  { _turn_stream       = stream
  , _turn_execTool     = execTool
  , _turn_emit         = emit
  , _turn_record       = record
  , _turn_nextStreamId = next
  , _turn_model        = ModelId "fake-model"
  , _turn_systemPrompt = Nothing
  , _turn_tools        = []
  , _turn_maxTokens    = Just 4096
  }

-- A tool-use block helper.
toolUse :: Text -> Text -> P.ContentBlock
toolUse cid name = P.ToolUseBlock (ToolCallId cid) name Aeson.Null

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "TurnEvent instances" $ do
    it "has a Show instance covering all three constructors" $ do
      let sid = mkStreamId 7
      show (TurnStart sid)        `shouldContain` "TurnStart"
      show (TurnChunk sid "hi")   `shouldContain` "TurnChunk"
      show (TurnEnd sid)          `shouldContain` "TurnEnd"
    it "has an Eq instance that distinguishes constructors" $ do
      let sid = mkStreamId 1
      TurnStart sid             `shouldBe` TurnStart sid
      TurnStart sid             `shouldNotBe` TurnEnd sid
      TurnChunk sid "a"         `shouldNotBe` TurnChunk sid "b"

  describe "runTurnWithTools — request building" $ do
    it "builds the CompletionRequest from model/system/tools/maxTokens + context" $ do
      reqRef  <- Ref.newIORef (Nothing :: Maybe P.CompletionRequest)
      let toolDef = P.ToolDefinition "search" "find things" Aeson.Null
          capturingStream req cb = do
            Ref.writeIORef reqRef (Just req)
            cb (P.StreamDone (mkResp [P.TextBlock "ok"]))
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = (mkDeps capturingStream (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef))
                   { _turn_model        = ModelId "captured-model"
                   , _turn_systemPrompt = Just "be terse"
                   , _turn_tools        = [toolDef]
                   , _turn_maxTokens    = Just 2048
                   }
      _ <- runTurnWithTools deps (Ctx.emptyContext (Just "be terse")) "ping"
      Just req <- Ref.readIORef reqRef
      P._cr_model req        `shouldBe` ModelId "captured-model"
      P._cr_systemPrompt req `shouldBe` Just "be terse"
      P._cr_tools req        `shouldBe` [toolDef]
      P._cr_maxTokens req    `shouldBe` Just 2048
      P._cr_toolChoice req   `shouldBe` Nothing
      -- the user message is present in the request's message list
      map P._msg_role (P._cr_messages req) `shouldBe` [P.User]

    it "falls back to the context system prompt when deps prompt is Nothing" $ do
      reqRef  <- Ref.newIORef (Nothing :: Maybe P.CompletionRequest)
      let capturingStream req cb = do
            Ref.writeIORef reqRef (Just req)
            cb (P.StreamDone (mkResp [P.TextBlock "ok"]))
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps capturingStream (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)  -- _turn_systemPrompt defaults to Nothing
      _ <- runTurnWithTools deps (Ctx.emptyContext (Just "from-context")) "ping"
      Just req <- Ref.readIORef reqRef
      P._cr_systemPrompt req `shouldBe` Just "from-context"

  describe "runTurnWithTools — single turn, no tools" $ do
    it "emits TurnStart, chunks in order, TurnEnd; context = [user, assistant]" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamText "Hello "
          , P.StreamText "world"
          , P.StreamDone (mkResp [P.TextBlock "Hello world"])
          ]
        ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      evs <- Ref.readIORef emits
      let sid0 = mkStreamId 0
      evs `shouldBe`
        [ TurnStart sid0
        , TurnChunk sid0 "Hello "
        , TurnChunk sid0 "world"
        , TurnEnd sid0
        ]
      let msgs = Ctx.contextMessages ctx
      map P._msg_role msgs `shouldBe` [P.User, P.Assistant]
      -- force the user-text and assistant-content message bodies
      map P._msg_content msgs
        `shouldBe` [ [P.TextBlock "hi"], [P.TextBlock "Hello world"] ]

    it "non-streaming provider (only StreamDone, no StreamText) emits the full text as one chunk" $ do
      -- Regression for #79 8d: Ollama-style providers (stream=False) emit only a
      -- single StreamDone with the whole response and no incremental StreamText,
      -- so without a fallback nothing reaches the relay/screen. The turn must
      -- emit the full response text as one TurnChunk so it is displayed.
      scripts <- Ref.newIORef
        [ [ P.StreamDone (mkResp [P.TextBlock "the whole reply"]) ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      _ <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      evs <- Ref.readIORef emits
      let sid0 = mkStreamId 0
      evs `shouldBe`
        [ TurnStart sid0
        , TurnChunk sid0 "the whole reply"
        , TurnEnd sid0
        ]

    it "records user then assistant message to the transcript" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamText "ok", P.StreamDone (mkResp [P.TextBlock "ok"]) ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      _ <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      recs <- Ref.readIORef records
      map P._msg_role recs `shouldBe` [P.User, P.Assistant]

  describe "runTurnWithTools — tool cycle" $ do
    it "executes the tool, re-completes, and finishes (user, asst1, toolResult, asst2)" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamDone (mkResp [P.TextBlock "calling", toolUse "c1" "search"]) ]
        , [ P.StreamDone (mkResp [P.TextBlock "done"]) ]
        ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "go"
      execed <- Ref.readIORef execRef
      execed `shouldBe` [(ToolCallId "c1", "search")]
      map P._msg_role (Ctx.contextMessages ctx)
        `shouldBe` [P.User, P.Assistant, P.User, P.Assistant]
      -- two stream cycles -> two TurnStart events
      evs <- Ref.readIORef emits
      length [() | TurnStart _ <- evs] `shouldBe` 2

    it "records user, assistant, tool-result, assistant in order" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamDone (mkResp [toolUse "c1" "search"]) ]
        , [ P.StreamDone (mkResp [P.TextBlock "done"]) ]
        ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      _ <- runTurnWithTools deps (Ctx.emptyContext Nothing) "go"
      recs <- Ref.readIORef records
      map P._msg_role recs `shouldBe` [P.User, P.Assistant, P.User, P.Assistant]

    it "executes BOTH tool calls in a multi-tool response before re-completing" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamDone (mkResp [toolUse "c1" "alpha", toolUse "c2" "beta"]) ]
        , [ P.StreamDone (mkResp [P.TextBlock "done"]) ]
        ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      _ <- runTurnWithTools deps (Ctx.emptyContext Nothing) "go"
      execed <- Ref.readIORef execRef
      execed `shouldBe` [(ToolCallId "c1", "alpha"), (ToolCallId "c2", "beta")]

  describe "runTurnWithTools — streaming order" $ do
    it "emits chunks as TurnChunk in arrival order" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamText "a", P.StreamText "b", P.StreamText "c"
          , P.StreamDone (mkResp [P.TextBlock "abc"]) ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      _ <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      evs <- Ref.readIORef emits
      [ t | TurnChunk _ t <- evs ] `shouldBe` ["a", "b", "c"]

  describe "runTurnWithTools — warning handling" $ do
    it "tolerates StreamWarning (no emit, no crash) and still completes" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamWarning "recovered malformed tool input"
          , P.StreamText "x"
          , P.StreamDone (mkResp [P.TextBlock "x"]) ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      map P._msg_role (Ctx.contextMessages ctx) `shouldBe` [P.User, P.Assistant]
      evs <- Ref.readIORef emits
      [ t | TurnChunk _ t <- evs ] `shouldBe` ["x"]

    it "ignores incremental StreamToolUse / StreamToolInput events (no emit)" $ do
      scripts <- Ref.newIORef
        [ [ P.StreamToolUse (ToolCallId "c1") "search"
          , P.StreamToolInput "{\"q\":"
          , P.StreamToolInput "1}"
          , P.StreamText "x"
          , P.StreamDone (mkResp [P.TextBlock "x"]) ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      map P._msg_role (Ctx.contextMessages ctx) `shouldBe` [P.User, P.Assistant]
      evs <- Ref.readIORef emits
      -- only the text chunk is surfaced; the incremental tool events are silent
      [ t | TurnChunk _ t <- evs ] `shouldBe` ["x"]

  describe "runTurnWithTools — provider error" $ do
    it "does not throw when the stream throws; returns ctx with user msg; emits TurnEnd" $ do
      let boom _req _cb = E.throwIO (userError "provider boom")
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps boom (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      map P._msg_role (Ctx.contextMessages ctx) `shouldBe` [P.User]
      evs <- Ref.readIORef emits
      let sid0 = mkStreamId 0
      evs `shouldBe` [TurnStart sid0, TurnEnd sid0]

    it "does not throw when the stream emits no StreamDone; returns ctx with user msg" $ do
      scripts <- Ref.newIORef [ [ P.StreamText "partial" ] ]
      emits   <- Ref.newIORef []
      records <- Ref.newIORef []
      sidRef  <- Ref.newIORef 0
      execRef <- Ref.newIORef []
      let deps = mkDeps (scriptedStream scripts) (recordingExec execRef)
                        (recordingEmit emits) (recordingRecord records)
                        (nextSid sidRef)
      ctx <- runTurnWithTools deps (Ctx.emptyContext Nothing) "hi"
      map P._msg_role (Ctx.contextMessages ctx) `shouldBe` [P.User]
      evs <- Ref.readIORef emits
      let sid0 = mkStreamId 0
      evs `shouldBe` [TurnStart sid0, TurnChunk sid0 "partial", TurnEnd sid0]
