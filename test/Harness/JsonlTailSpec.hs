module Harness.JsonlTailSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Word (Word8)
import Test.Hspec
import Test.QuickCheck

import PureClaw.Harness.JsonlTail

-- | Convenience: run 'splitLines' on a chunk starting from the empty buffer,
-- returning the emitted line bytes and the residual buffer bytes.
runEmpty :: ByteString -> ([ByteString], ByteString)
runEmpty chunk =
  let (ls, buf) = splitLines chunk emptyBuffer
   in (map unCompleteLine ls, unBuffer buf)

spec :: Spec
spec = do
  describe "emptyBuffer / Buffer (D4.1)" $ do
    it "emptyBuffer holds no bytes" $
      unBuffer emptyBuffer `shouldBe` BS.empty

  describe "splitLines: single inputs (D4.2)" $ do
    it "emits a single complete line without its trailing LF" $
      runEmpty "hello\n" `shouldBe` (["hello"], "")

    it "emits multiple complete lines in order" $
      runEmpty "a\nb\nc\n" `shouldBe` (["a", "b", "c"], "")

    it "buffers a trailing partial (un-terminated) line and emits nothing for it" $
      runEmpty "a\nb\npartial" `shouldBe` (["a", "b"], "partial")

    it "empty input yields no lines and leaves the buffer unchanged" $ do
      let (ls, buf) = splitLines BS.empty emptyBuffer
      ls `shouldBe` []
      unBuffer buf `shouldBe` BS.empty

    it "input with no LF buffers the whole chunk and emits nothing" $
      runEmpty "no newline here" `shouldBe` ([], "no newline here")

  describe "splitLines: LF edge cases (D4.2)" $ do
    it "a single lone LF emits one empty line" $
      runEmpty "\n" `shouldBe` ([""], "")

    it "consecutive LFs (\\n\\n) emit empty lines between them" $
      runEmpty "a\n\nb\n" `shouldBe` (["a", "", "b"], "")

    it "leading LF emits a leading empty line" $
      runEmpty "\nx\n" `shouldBe` (["", "x"], "")

    it "trailing content after the last LF is buffered, not emitted" $
      runEmpty "x\ny" `shouldBe` (["x"], "y")

  describe "splitLines: carriage return is preserved (D4.2)" $ do
    it "does NOT strip a CR before an LF (input \"a\\r\\nb\\n\")" $
      runEmpty "a\r\nb\n" `shouldBe` (["a\r", "b"], "")

    it "keeps a CR inside the buffered partial line" $
      runEmpty "a\r" `shouldBe` ([], "a\r")

  describe "splitLines: reassembly across two chunks (D4.2)" $ do
    it "reassembles a line split across two reads once the LF arrives" $ do
      let (ls1, buf1) = splitLines "hel" emptyBuffer
          (ls2, buf2) = splitLines "lo\n" buf1
      map unCompleteLine ls1 `shouldBe` []
      map unCompleteLine ls2 `shouldBe` ["hello"]
      unBuffer buf2 `shouldBe` ""

    it "completes a previously-buffered partial line when the LF chunk arrives" $ do
      let (_, buf1) = splitLines "abc" emptyBuffer
          (ls2, buf2) = splitLines "\n" buf1
      map unCompleteLine ls2 `shouldBe` ["abc"]
      unBuffer buf2 `shouldBe` ""

    it "carries a new partial after emitting completed lines" $ do
      let (_, buf1) = splitLines "a" emptyBuffer
          (ls2, buf2) = splitLines "bc\ndef" buf1
      map unCompleteLine ls2 `shouldBe` ["abc"]
      unBuffer buf2 `shouldBe` "def"

    it "prepends the incoming buffer to the new chunk (buffer comes first)" $ do
      let (_, buf1) = splitLines "X" emptyBuffer
          (ls2, _) = splitLines "Y\n" buf1
      map unCompleteLine ls2 `shouldBe` ["XY"]

  describe "splitLines: CompleteLine accessor (D4.1)" $
    it "unCompleteLine returns the raw line bytes" $ do
      let (ls, _) = splitLines "one\ntwo\n" emptyBuffer
      map unCompleteLine ls `shouldBe` ["one", "two"]

  describe "splitLinesBounded" $ do
    it "splitLinesBounded passes complete lines through under the cap" $ do
      case splitLinesBounded 1024 "a\nb\n" emptyBuffer of
        Left e -> expectationFailure ("unexpected OverCap: " <> show e)
        Right (ls, buf) -> do
          map unCompleteLine ls `shouldBe` ["a", "b"]
          unBuffer buf `shouldBe` ""

    it "splitLinesBounded buffers a partial trailing line under the cap" $ do
      case splitLinesBounded 1024 "a\npart" emptyBuffer of
        Left e -> expectationFailure ("unexpected OverCap: " <> show e)
        Right (ls, buf) -> do
          map unCompleteLine ls `shouldBe` ["a"]
          unBuffer buf `shouldBe` "part"

    it "splitLinesBounded rejects a no-LF line exceeding the cap (OverCap, no growth)" $ do
      let big = BS.replicate 2048 0x61   -- 2048 'a', no newline
      splitLinesBounded 1024 big emptyBuffer `shouldBe` Left OverCap

    it "splitLinesBounded rejects when pending+chunk exceeds cap with no LF" $ do
      case splitLinesBounded 4096 "head" emptyBuffer of
        Left e -> expectationFailure ("unexpected OverCap seeding buffer: " <> show e)
        Right (_, buf) ->
          splitLinesBounded 8 "morebytes_overflow" buf `shouldBe` Left OverCap

  describe "splitLines: round-trip property (D4.2)" $ do
    it "feeding any input as a single chunk reconstructs it" $
      property $ \(ws :: [Word8Wrapper]) ->
        let input = BS.pack (map unWord8Wrapper ws)
            (ls, buf) = splitLines input emptyBuffer
            reconstructed = reassemble (map unCompleteLine ls) (unBuffer buf)
         in reconstructed === input

    it "feeding input in arbitrary chunk splits reconstructs the original" $
      property $ \(ws :: [Word8Wrapper]) (splits :: [NonNegative Int]) ->
        let input = BS.pack (map unWord8Wrapper ws)
            chunks = chunkBy (map getNonNegative splits) input
            (ls, buf) = feedChunks chunks
            reconstructed = reassemble (map unCompleteLine ls) (unBuffer buf)
         in reconstructed === input

    it "chunked feeding yields the same lines+residual as a single chunk" $
      property $ \(ws :: [Word8Wrapper]) (splits :: [NonNegative Int]) ->
        let input = BS.pack (map unWord8Wrapper ws)
            chunks = chunkBy (map getNonNegative splits) input
            (lsChunked, bufChunked) = feedChunks chunks
            (lsWhole, bufWhole) = splitLines input emptyBuffer
         in ( map unCompleteLine lsChunked
            , unBuffer bufChunked
            )
              === ( map unCompleteLine lsWhole
                  , unBuffer bufWhole
                  )

-- | Reconstruct the original byte stream from emitted lines plus the residual
-- buffer. Each emitted line had its terminating LF stripped, so we re-add one
-- LF per line; the residual buffer is whatever trailing partial remained.
reassemble :: [ByteString] -> ByteString -> ByteString
reassemble ls residual =
  BS.concat (map (\l -> l <> BSC.singleton '\n') ls) <> residual

-- | Feed a list of chunks through 'splitLines', threading the buffer, and
-- collect all emitted lines in order plus the final residual buffer.
feedChunks :: [ByteString] -> ([CompleteLine], Buffer)
feedChunks = go [] emptyBuffer
  where
    go acc buf [] = (acc, buf)
    go acc buf (c : cs) =
      let (ls, buf') = splitLines c buf
       in go (acc <> ls) buf' cs

-- | Split a 'ByteString' into chunks at the given sequence of cut lengths.
-- Each length consumes that many bytes (clamped to what remains); any leftover
-- after the lengths are exhausted becomes a final chunk.
chunkBy :: [Int] -> ByteString -> [ByteString]
chunkBy [] bs
  | BS.null bs = []
  | otherwise = [bs]
chunkBy (n : ns) bs
  | BS.null bs = []
  | otherwise =
      let m = min (max 0 n) (BS.length bs)
          (h, t) = BS.splitAt m bs
       in h : chunkBy ns t

-- | A 'Word8' wrapper whose 'Arbitrary' instance is biased toward producing
-- LF bytes (0x0A) and CR bytes (0x0D) so generated inputs exercise line
-- boundaries and CR-preservation densely.
newtype Word8Wrapper = Word8Wrapper {unWord8Wrapper :: Word8}
  deriving (Eq, Show)

instance Arbitrary Word8Wrapper where
  arbitrary =
    Word8Wrapper
      <$> frequency
        [ (3, pure 0x0A) -- LF
        , (1, pure 0x0D) -- CR
        , (6, arbitrary) -- any byte
        ]
  shrink (Word8Wrapper w) = Word8Wrapper <$> shrink w
