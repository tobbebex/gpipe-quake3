{-# LANGUAGE ScopedTypeVariables, PackageImports, TypeFamilies, FlexibleContexts, RecordWildCards, LambdaCase #-}
module Render where

import Control.Monad.Exception (MonadException)
import Control.Monad.IO.Class
import Graphics.GPipe
import qualified Graphics.GPipe.Context.GLFW as GLFW
import qualified Graphics.GPipe.Context.GLFW.Input as Input
import "lens" Control.Lens
import Control.Monad (unless,zipWithM,forM)
import Data.Word (Word32,Word8)
import Control.Applicative (pure)
import Data.Monoid (mappend)

import qualified Data.ByteString as SB
import qualified Data.Map as Map
import qualified Data.Trie as T
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import Codec.Picture as Juicy
import Codec.Picture.Types
import Data.Bits
import Data.Int
import BSP
import Camera
import Q3Patch
import Material
import Graphics

import Data.List (foldl',scanl')

tessellatePatch :: V.Vector DrawVertex -> Int -> Surface -> (V.Vector DrawVertex,V.Vector Int)
tessellatePatch drawV level sf@Surface{..} = case srSurfaceType of
  Patch -> (V.concat vl,V.concat il)
    where
      (w,h)   = srPatchSize
      gridF :: [DrawVertex] -> [[DrawVertex]]
      gridF l = case splitAt w l of
          (x,[])  -> [x]
          (x,xs)  -> x:gridF xs
      grid        = gridF $ V.toList $ V.take srNumVertices $ V.drop srFirstVertex drawV
      controls    = [V.fromList $ concat [take 3 $ drop x l | l <- lines] | x <- [0,2..w-3], y <- [0,2..h-3], let lines = take 3 $ drop y grid]
      patches     = [tessellate c level | c <- controls]
      (vl,il)     = unzip $ reverse $ snd $ foldl' (\(o,l) (v,i) -> (o+V.length v, (v,V.map (+o) i):l)) (0,[]) patches
  _ -> mempty

convertSurface BSPLevel{..} indexBufferQ3 vertexBufferQ3 lightmapCount patchInfo sf@Surface{..} = do
  let Shader name sfFlags _ = blShaders V.! srShaderNum
      noDraw = sfFlags .&. 0x80 /= 0
      lightmap = toFloat (if srLightmapNum < 0 || srLightmapNum > lightmapCount then lightmapCount else srLightmapNum)
      emitStream prim firstVertex numVertices firstIndex numIndices = if noDraw then return (0,mempty) else do
        vertexArrayQ3 <- (takeVertices numVertices . dropVertices firstVertex) <$> newVertexArray vertexBufferQ3
        indexArrayQ3 <- (takeIndices numIndices . dropIndices firstIndex) <$> newIndexArray indexBufferQ3 Nothing
        return (srShaderNum, (,) lightmap <$> toPrimitiveArrayIndexed prim indexArrayQ3 vertexArrayQ3)
  case srSurfaceType of
    Flare -> return (srShaderNum,mempty)
    Patch -> let ((firstVertex,firstIndex),(numVertices,numIndices)) = patchInfo
             in emitStream TriangleStrip firstVertex numVertices firstIndex numIndices
    _ -> emitStream TriangleList srFirstVertex srNumVertices srFirstIndex srNumIndices

type CF = WindowFormat RGBAFloat Depth
type AttInput = (B3 Float, B3 Float, B2 Float, B2 Float, B4 Float)
type A = PrimitiveArray Triangles AttInput
type Tables os = (Texture1D os (Format RFloat),
                  Texture1D os (Format RFloat),
                  Texture1D os (Format RFloat),
                  Texture1D os (Format RFloat),
                  Texture1D os (Format RFloat))
type UniInput = (B2 Int32, (B3 Float, B Float, B Float, B Float, B3 Float, B3 Float, B3 Float))

missingMaterial :: (ContextHandler w, MonadIO m, MonadException m) => Window os RGBAFloat Depth -> Buffer os (Uniform UniInput) -> ContextT w os m (CompiledShader os (RenderInput os))
missingMaterial win uniformBuffer = do
 liftIO (putStr "-")
 compileShader $ do
  uni <- getUniform (const (uniformBuffer,0))
  primitiveStream <- toPrimitiveStream riStream
  let viewMat = lookAt' (viewOrigin uni) (viewTarget uni) (viewUp uni)
      V2 w h  = windowSize uni
      projMat = perspective (pi/3) (toFloat w / toFloat h) 1 10000
      make3d (V3 x y z) = projMat !*! viewMat !* V4 x y z 1
      primitiveStream2 = fmap (\(_, (pos,_,_,_,color)) -> (make3d pos, color)) primitiveStream
  fragmentStream <- rasterize (\ri -> (FrontAndBack, ViewPort (V2 0 0) (riScreenSize ri), DepthRange 0 1)) primitiveStream2
  let fragmentStream2 = withRasterizedInfo (\a r -> (a, rasterizedFragCoord r ^. _z)) fragmentStream
  drawWindowColorDepth (const (win,ContextColorOption NoBlending (pure True),DepthOption Lequal True)) fragmentStream2

compileMaterial :: (ContextHandler w, MonadIO m, MonadException m) => Window os RGBAFloat Depth -> (Texture2DArray os (Format RGBFloat)) -> Texture2D os (Format RGBAFloat) -> T.Trie (Texture2D os (Format RGBAFloat)) -> Tables os -> Buffer os (Uniform UniInput) -> CommonAttrs -> ContextT w os m (CompiledShader os (RenderInput os))
compileMaterial win lightMap checkerTex texInfo tables uniformBuffer shaderInfo = do
 liftIO (putStr ".")
 compileShader $ do
  uni <- getUniform (const (uniformBuffer,0))
  let filter = SamplerFilter Linear Linear Linear Nothing
      edge = (Repeat, undefined)
      (sinT,squareT,sawT,invSawT,triT) = tables
  wt <- WaveTable <$> newSampler1D (const (sinT, filter, edge))
                  <*> newSampler1D (const (squareT, filter, edge))
                  <*> newSampler1D (const (sawT, filter, edge))
                  <*> newSampler1D (const (invSawT, filter, edge))
                  <*> newSampler1D (const (triT, filter, edge))
                  <*> newSampler1D (const (triT, filter, edge)) -- TODO: generate noise
  mkShader win lightMap checkerTex texInfo wt uni shaderInfo

renderQuake :: V3 Float -> BSPLevel -> T.Trie CommonAttrs -> T.Trie (Juicy.Image PixelRGBA8) -> IO ()
renderQuake startPos bsp@BSPLevel{..} shaderInfo imageInfo =
  runContextT (GLFW.defaultHandleConfig { GLFW.configEventPolicy = Nothing }) $ do
    win <- newWindow (WindowFormatColorDepth RGBA32F Depth32) (GLFW.defaultWindowConfig "Q3 Viewer")

    -- pre tesselate patches and append to static draw verices and indices
    let patches     = map (tessellatePatch blDrawVertices 5) $ V.toList blSurfaces
        (verticesQ3,indicesQ3) = mconcat $ (blDrawVertices,blDrawIndices):patches
        patchSize   = [(V.length v, V.length i) | (v,i) <- patches]
        patchOffset = scanl' (\(offsetV,offsetI) (v,i) -> (offsetV + v, offsetI + i)) (V.length blDrawVertices, V.length blDrawIndices) patchSize
        patchInfo   = zip patchOffset patchSize

    vertexBufferQ3 :: Buffer os AttInput <- newBuffer (V.length verticesQ3)
    writeBuffer vertexBufferQ3 0 [(dvPosition, dvNormal, dvDiffuseUV, dvLightmaptUV, dvColor) | DrawVertex{..} <- V.toList verticesQ3]

    indexBufferQ3 :: Buffer os (B Word32) <- newBuffer $ V.length indicesQ3
    writeBuffer indexBufferQ3 0 $ map fromIntegral $ V.toList indicesQ3

    -- for wave functions
    tables <- setupTables

    uniformBuffer :: Buffer os (Uniform UniInput) <- newBuffer 1

    -- load lightmap textures
    let toRGB (r:g:b:l) = V3 r g b : toRGB l
        toRGB _ = []
        lightmapCount = (V.length blLightmaps)
    lightmapArray <- newTexture2DArray RGB8 (V3 128 128 (lightmapCount+1)) 1
    V.forM_ (V.indexed blLightmaps) $ \(i, lm) ->
      writeTexture2DArray lightmapArray 0 (V3 0 0 i) (V3 128 128 1) $ toRGB . SB.unpack . lmMap $ lm
    -- Write a white texture last
    writeTexture2DArray lightmapArray 0 (V3 0 0 lightmapCount) (V3 128 128 1) (repeat (V3 1 1 (1::Float)))

    -- load diffuse textures
    checkerTex <- newTexture2D RGBA8 (V2 8 8) 1
    let whiteBlack = cycle [V4 0 0 0 1, V4 1 1 0 1] :: [V4 Float]
        blackWhite = tail whiteBlack
    writeTexture2D checkerTex 0 0 (V2 8 8) (cycle (take 8 whiteBlack ++ take 8 blackWhite))

    let mkTex i@(Image w h _) = do
          tex <- newTexture2D SRGB8A8 (V2 w h) (floor ((max (log (fromIntegral w :: Float)) (log (fromIntegral h :: Float))) / log 2) :: Int)
          writeTexture2D tex 0 0 (V2 w h) $ pixelFoldMap (\(PixelRGBA8 r g b a) -> [V4 r g b a]) i
          generateTexture2DMipmap tex
          return tex
    texInfo <- sequence $ mkTex <$> imageInfo

    -- shader for unknown materials
    missingMaterialShader <- missingMaterial win uniformBuffer

    --  create shader for each material
    usedShaders <- mapM (\Shader{..} -> maybe (return missingMaterialShader) (compileMaterial win lightmapArray checkerTex texInfo tables uniformBuffer) $ T.lookup shName shaderInfo) blShaders
    let surfaces vpSize = do
          surface0 <- zipWithM (convertSurface bsp indexBufferQ3 vertexBufferQ3 lightmapCount) patchInfo $ V.toList blSurfaces
          -- group surfaces by material
          let surface1 = Map.unionsWith mappend . map (\(k,v) -> Map.singleton k [v]) $ surface0
              --surface1 = Map.unionsWith mappend . map (uncurry Map.singleton) $ surface0
              surface2 = Map.mapWithKey
                (\shader surface ->
                  ( caSort <$> T.lookup (shName $ blShaders V.! shader) shaderInfo
                  -- pass to shader every per render varying input
                  --  geometry, diffuse texture, lightmap texture
                  , (usedShaders V.! shader) (RenderInput vpSize (mconcat surface))
                  )
                ) surface1
              -- sort surfaces by render queue
              sorted = concat $ Map.elems $ Map.unionsWith mappend [Map.singleton k [v] | (k,v) <- Map.elems surface2]
              allSurf = sequence_ sorted
          allSurf

    liftIO $ putStrLn "Hello 1"
    liftIO $ GLFW.setTime 0
    Just t0 <- liftIO $ GLFW.getTime
    renderLoop win uniformBuffer (s0 startPos) t0 surfaces

renderLoop win uniformBuffer s t renderings = do
  -- read input
  Just (mx,my) <- Input.getCursorPos win
  let keyIsPressed k = fmap (== Input.KeyState'Pressed) . fmap (maybe Input.KeyState'Released id) $ Input.getKey win k
  keys <- (,,,,) <$> keyIsPressed Input.Key'Left
                 <*> keyIsPressed Input.Key'Up
                 <*> keyIsPressed Input.Key'Down
                 <*> keyIsPressed Input.Key'Right
                 <*> keyIsPressed Input.Key'RightShift
  Just t' <- liftIO $ GLFW.getTime

  size <- getFrameBufferSize win
  let s'@(eye,center,up,_) = calcCam (t'-t) (realToFrac mx, realToFrac my) keys s
{-
  uniform tuple:
      entityRGB, entityAlpha, identityLight, time,  viewOrigin, viewTarget, viewUp
      (V3 Float, Float,       Float,         Float, V3 Float,   V3 Float,   V3 Float)
-}
  writeBuffer uniformBuffer 0 [(fromIntegral <$> size,(V3 1 1 1, 1, 1, realToFrac t', eye, center, up))]

  render $ do
    clearWindowColor win 0.5
    clearWindowDepth win 1
    renderings size

  swapWindowBuffers win
  Just closeRequested <- GLFW.windowShouldClose win
  unless closeRequested $ do
    GLFW.mainstep win GLFW.Poll
    renderLoop win uniformBuffer s' t' renderings

-- Utility code
tableTexture table = do
  let size = length table
      --f :: Float -> Normalized Word32
      --f x = floor $ min 255 $ max 0 $ 128 + 128 * x
  tex <- newTexture1D R8 size 1
  writeTexture1D tex 0 0 size (table :: [Float]) -- $ map f table
  return tex

setupTables = do
  let funcTableSize = 1024 :: Float
      sinTexture              = [sin (i*2*pi/(funcTableSize-1)) | i <- [0..funcTableSize-1]]
      squareTexture           = [if i < funcTableSize / 2 then 1 else -1 | i <- [0..funcTableSize-1]]
      sawToothTexture         = [i / funcTableSize | i <- [0..funcTableSize-1]]
      inverseSawToothTexture  = reverse [i / funcTableSize | i <- [0..funcTableSize-1]]
      triangleTexture         = l1 ++ map ((-1)*) l1
        where
          n = funcTableSize / 4
          l0 = [i / n | i <- [0..n-1]]
          l1 = l0 ++ reverse l0

  (,,,,) <$> tableTexture sinTexture
         <*> tableTexture squareTexture
         <*> tableTexture sawToothTexture
         <*> tableTexture inverseSawToothTexture
         <*> tableTexture triangleTexture
