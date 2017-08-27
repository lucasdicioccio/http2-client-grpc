{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Lib
    ( someFunc
    ) where

import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

import Data.Default.Class (def)
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher as TLS

import Data.Proxy
import qualified Data.ByteString as ByteString
import Data.Int
import Data.ProtocolBuffers
import Data.Serialize
import Data.Text
import Data.Word
import GHC.Generics (Generic)
import GHC.TypeLits

data HelloRequest = HelloRequest {
    helloRequestName :: Required 1 (Value Text)
  } deriving(Generic, Show)
instance Encode HelloRequest
instance Decode HelloRequest

data HelloReply = HelloReply {
    helloReplyMessage :: Required 1 (Value Text)
  } deriving(Generic, Show)
instance Encode HelloReply
instance Decode HelloReply

sendMessage :: Encode a => Http2Client -> Http2Stream -> FlagSetter -> a -> IO ()
sendMessage conn stream flagmod msg = 
    sendData conn stream flagmod (encodePlainMessage msg)
  where
    encodePlainMessage msg = runPut $ do
        let bin = runPut $ encodeMessage msg
        put (0 :: Int8)
        put (fromIntegral (ByteString.length bin) :: Word32)
        putByteString bin

decodeResult :: Decode a => ByteString.ByteString -> Either String a
decodeResult bin = runGet go bin
  where
    go = do
        (0 :: Int8) <- get
        (n :: Word32) <- get
        if ByteString.length bin < fromIntegral (1 + 4 + n)
        then
            fail "not enough data for decoding"
        else 
            decodeMessage

type Reply a = ((FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, Either ErrorCode (Either String a)))

waitReply :: Decode a => Http2Stream -> IO (Reply a)
waitReply stream = do
    h0 <- _waitHeaders stream
    msg <- fmap f (_waitData stream)
    h1 <- _waitHeaders stream
    return (h0, h1, msg)
  where
    f (hdrs, dat) = (hdrs, fmap decodeResult dat)

class (Encode a, Decode b) => RPC a b where
    path :: Proxy (a,b) -> ByteString.ByteString
  
instance RPC HelloRequest HelloReply where
    path _ = "/helloworld.Greeter/SayHello"


call :: RPC a b => Http2Client -> a -> IO (Either TooMuchConcurrency (Reply b))
call = callProxy (Proxy :: Proxy (a,b))

callProxy :: RPC a b => Proxy (a,b) -> Http2Client -> a -> IO (Either TooMuchConcurrency (Reply b))
callProxy proxy conn req = do
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", "localhost")
                  , (":path", path proxy)
                  , ("grpc-timeout", "1S")
                  , ("content-type", "application/grpc+proto")
                  , ("grpc-encoding", "gzip")
                  , ("te", "trailers")
                  ]
    withHttp2Stream conn $ \stream ->
        let
            initStream = headers stream request (setEndHeader)
            handler isfc osfc = do
                sendMessage conn stream setEndStream req
                waitReply stream 
        in StreamDefinition initStream handler

someFunc :: IO ()
someFunc = do
    conn <- newHttp2Client "127.0.0.1" 50051 8192 8192 tlsParams []

    let ifc = _incomingFlowControl conn
    let ofc = _outgoingFlowControl conn
    _addCredit ifc 1000000
    _ <- _updateWindow ifc
    print =<< (call conn (HelloRequest (putField "world"))  :: IO (Either TooMuchConcurrency (Reply HelloReply)))
    putStrLn "done"


tlsParams :: ClientParams
tlsParams = TLS.ClientParams {
    TLS.clientWantSessionResume = Nothing
  , TLS.clientUseMaxFragmentLength = Nothing
  , TLS.clientServerIdentification = ("127.0.0.1", "")
  , TLS.clientUseServerNameIndication = False
  , TLS.clientShared = def
  , TLS.clientHooks = def { TLS.onServerCertificate = \_ _ _ _ -> return [] }
  , TLS.clientSupported = def { TLS.supportedCiphers = TLS.ciphersuite_default }
  , TLS.clientDebug = def
  }
