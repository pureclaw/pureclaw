-- |
-- Module      : Routing.DispatcherSpec
-- Description : WU0 red-phase scaffold for dispatcher + concurrency DoDs (C-series).
--
-- Enumerates the C-series Definition-of-Done items from
-- @docs/tabbed-chat.md@ §"Concurrency & exception safety (C-series)" as
-- 'pending' tests. The production module @PureClaw.Routing.Dispatcher@
-- and 'spawnTab' indirection land in WU5; per-kind crash-isolation
-- assertions inside the AI loop land in WU6.
module Routing.DispatcherSpec (spec) where

import Test.Hspec

spec :: Spec
spec = do
  describe "C-series — concurrency + exception safety (WU0 scaffold; WU5/WU6 fill in)" $ do
    it "C1: tabs run in their own threads — slow /0 plus immediate /1 ping, /1 response observed before /0 completes (uses T1 blocking provider)" pending
    it "C2: AI tab state isolation — /0 /target sonnet does not change /1's model IORef" pending
    it "C3: tab spawn is exception-safe — factory throw mid-construction leaves _env_tabs unchanged and partially-allocated resources closed (mask-based spawn)" pending
    it "C4: dispatcher death cancels all tabs — bracket (newIORef IntMap.empty) cancelAll dispatcherBody; cancelAll fires on exception AND graceful EOF" pending
    it "C5: crash isolation — tab loop catches SomeException except AsyncCancelled; status becomes Crashed; dispatcher does not crash; close leaves status Closing not Crashed" pending
    it "C6: provider cancellation safety — cancel mid-stream leaves transcript in {full-prefix-with-cancel-marker, no-partial} (uses T1 blocking provider)" pending
