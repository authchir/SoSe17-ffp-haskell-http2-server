module Frame.Headers
 ( Payload
 , getHeaderFragment
 , getPayload
 , mkPayload
 , putPayload
 , toString
 , endStreamF
 , endHeadersF
 , paddedF
 , priorityF
 , isEndStream
 , isEndHeaders
 , isPadded
 , hasPriority
)where

import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.Bits as Bits
import qualified Frame.Internal.Padding as Padding

import Control.Monad.Except(ExceptT)
import Control.Monad.Trans.Class(lift)
import Data.Binary.Get(Get)
import Data.Binary.Put(Put)
import Data.ByteString.Lazy (ByteString)

import Frame.Internal.Padding(PaddingDesc(..))
import ProjectPrelude
import ErrorCodes

data PriorityDesc = PriorityDesc {
  pdExclusive :: Bool,
  pdDependency :: StreamId,
  pdWeight :: Word8
} deriving Show

data Payload = Payload
  { pPriority :: Maybe PriorityDesc
  , pPadding  :: Maybe PaddingDesc
  , pBlockFragment :: ByteString
  }

endStreamF :: FrameFlags
endStreamF = 0x1

isEndStream :: FrameFlags -> Bool
isEndStream f = testFlag f endStreamF

endHeadersF :: FrameFlags
endHeadersF = 0x4

isEndHeaders :: FrameFlags -> Bool
isEndHeaders f = testFlag f endHeadersF

paddedF :: FrameFlags
paddedF = 0x8

isPadded :: FrameFlags -> Bool
isPadded f = testFlag f paddedF

priorityF :: FrameFlags
priorityF = 0x20

hasPriority :: FrameFlags -> Bool
hasPriority f = testFlag f priorityF

getHeaderFragment :: Payload -> ByteString
getHeaderFragment = pBlockFragment

mkPayload :: ByteString -> Payload
mkPayload pBlockFragment = Payload {
  pPriority = Nothing,
  pPadding = Nothing,
  pBlockFragment
}

testFlagPriority :: FrameFlags -> Bool
testFlagPriority = flip Bits.testBit 5

getPriority :: Get PriorityDesc
getPriority = do
  w <- Get.getWord32be
  let pdExclusive = Bits.testBit w 31
  let pdDependency = StreamId (Bits.clearBit w 31)
  pdWeight <- Get.getWord8
  return $ PriorityDesc { pdExclusive, pdDependency, pdWeight }

getPayload :: FrameLength -> FrameFlags -> StreamId -> ExceptT ConnError Get Payload
getPayload fLength flags _ = do
  (fLength, paddingLength) <- Padding.getLength fLength flags
  (fLength, pPriority) <- lift $
    if testFlagPriority flags then
      (,) (fLength - 5) . Just <$> getPriority
    else
      return (fLength, Nothing)
  pBlockFragment <- lift $ Get.getLazyByteString $
    fromIntegral (maybe fLength ((fLength -) . fromIntegral) paddingLength)
  pPadding <- lift $ Padding.getPadding paddingLength
  return $ Payload { pPriority, pPadding, pBlockFragment }

putPayload :: Payload -> Put
putPayload Payload { pPriority, pPadding, pBlockFragment } = do
  Padding.putLength pPadding
  case pPriority of
    Nothing -> return ()
    Just PriorityDesc { pdExclusive, pdDependency, pdWeight } -> do
      let StreamId x = pdDependency
      let w = if pdExclusive then Bits.setBit x 31 else x
      Put.putWord32be w
      Put.putWord8 pdWeight
  Put.putLazyByteString pBlockFragment
  Padding.putPadding pPadding

toString :: String -> Payload -> String
toString prefix Payload { pPriority, pPadding, pBlockFragment } =
  unlines $ map (prefix++) [
    "priority: " ++ show pPriority,
    "padding: " ++ show pPadding,
    "headers: " ++ show pBlockFragment
  ]
