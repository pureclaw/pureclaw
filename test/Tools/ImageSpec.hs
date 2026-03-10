module Tools.ImageSpec (spec) where

import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
import System.FilePath
import Test.Hspec

import PureClaw.Core.Types
import PureClaw.Handles.File
import PureClaw.Providers.Class
import PureClaw.Tools.Image

-- | Minimal PNG file (8-byte signature).
pngData :: BS.ByteString
pngData = BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

-- | Minimal JPEG file.
jpegData :: BS.ByteString
jpegData = BS.pack [0xff, 0xd8, 0xff, 0xe0]

withImageWorkspace :: (WorkspaceRoot -> IO a) -> IO a
withImageWorkspace action = do
  tmpDir <- getTemporaryDirectory
  let dir = tmpDir </> "pureclaw-image-test"
  createDirectoryIfMissing True dir
  BS.writeFile (dir </> "test.png") pngData
  BS.writeFile (dir </> "photo.jpg") jpegData
  BS.writeFile (dir </> "file.bmp") "not an image"
  action (WorkspaceRoot dir)

spec :: Spec
spec = do
  describe "detectMediaType" $ do
    it "detects PNG" $
      detectMediaType ".png" `shouldBe` Just "image/png"

    it "detects JPEG (.jpg)" $
      detectMediaType ".jpg" `shouldBe` Just "image/jpeg"

    it "detects JPEG (.jpeg)" $
      detectMediaType ".jpeg" `shouldBe` Just "image/jpeg"

    it "detects GIF" $
      detectMediaType ".gif" `shouldBe` Just "image/gif"

    it "detects WebP" $
      detectMediaType ".webp" `shouldBe` Just "image/webp"

    it "rejects unsupported formats" $ do
      detectMediaType ".bmp" `shouldBe` Nothing
      detectMediaType ".txt" `shouldBe` Nothing
      detectMediaType "" `shouldBe` Nothing

  describe "imageTool" $ do
    it "reads and base64-encodes a PNG image" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (_, handler) = imageTool root fh
      (parts, isErr) <- handler (object ["path" .= ("test.png" :: Text)])
      isErr `shouldBe` False
      length parts `shouldBe` 2
      case parts of
        (TRPImage mediaType b64 : TRPText desc : _) -> do
          mediaType `shouldBe` "image/png"
          B64.decode b64 `shouldBe` Right pngData
          T.unpack desc `shouldContain` "test.png"
        _ -> expectationFailure "expected TRPImage followed by TRPText"

    it "reads JPEG images" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (_, handler) = imageTool root fh
      (parts, isErr) <- handler (object ["path" .= ("photo.jpg" :: Text)])
      isErr `shouldBe` False
      case parts of
        (TRPImage mediaType _ : _) -> mediaType `shouldBe` "image/jpeg"
        _ -> expectationFailure "expected TRPImage"

    it "rejects unsupported formats" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (_, handler) = imageTool root fh
      (parts, isErr) <- handler (object ["path" .= ("file.bmp" :: Text)])
      isErr `shouldBe` True
      case parts of
        (TRPText t : _) -> T.unpack t `shouldContain` "Unsupported"
        _ -> expectationFailure "expected error text"

    it "rejects images exceeding size limit" $ withImageWorkspace $ \root -> do
      -- Create a file that exceeds the size limit (just over maxImageSize)
      let bigPath = unWorkspaceRoot root </> "huge.png"
          fh = mkFileHandle root
          (_, handler) = imageTool root fh
      -- Write a file slightly over the limit
      BS.writeFile bigPath (BS.replicate (maxImageSize + 1) 0)
      (parts, isErr) <- handler (object ["path" .= ("huge.png" :: Text)])
      isErr `shouldBe` True
      case parts of
        (TRPText t : _) -> T.unpack t `shouldContain` "too large"
        _ -> expectationFailure "expected error text"

    it "handles missing path parameter" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (_, handler) = imageTool root fh
      (_parts, isErr) <- handler (object [])
      isErr `shouldBe` True

    it "handles path traversal attacks" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (_, handler) = imageTool root fh
      (_parts, isErr) <- handler (object ["path" .= ("../../etc/passwd" :: Text)])
      isErr `shouldBe` True

    it "has correct tool name" $ withImageWorkspace $ \root -> do
      let fh = mkFileHandle root
          (def, _) = imageTool root fh
      _td_name def `shouldBe` "image"
