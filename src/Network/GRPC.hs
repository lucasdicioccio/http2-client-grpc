{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Network.GRPC where

import Data.Monoid ((<>))
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Binary.Builder (toLazyByteString, fromByteString, singleton, putWord32be)
import Data.Binary.Get (getByteString, getInt8, getWord32be, runGet)
import qualified Data.ByteString as ByteString
import Data.ProtoLens.Encoding (encodeMessage, decodeMessage)
import Data.ProtoLens.Message (Message)

import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

class (Message (Input n), Message (Output n)) => RPC n where
  type Input n
  type Output n
  path :: n -> ByteString.ByteString
  
sendMessage :: Message a => Http2Client -> Http2Stream -> FlagSetter -> a -> IO ()
sendMessage conn stream flagmod msg = 
    sendData conn stream flagmod (toStrict . toLazyByteString $ encodePlainMessage msg)
  where
    encodePlainMessage msg =
        let bin = encodeMessage msg
        in singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin

decodeResult :: Message a => ByteString.ByteString -> Either String a
decodeResult bin = runGet go (fromStrict bin)
  where
    go = do
        0 <- getInt8
        n <- getWord32be
        if ByteString.length bin < fromIntegral (1 + 4 + n)
        then
            fail "not enough data for decoding"
        else 
            decodeMessage <$> getByteString (fromIntegral n)

type Reply a = ((FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, Either ErrorCode (Either String a)))

waitReply :: Message a => Http2Stream -> IO (Reply a)
waitReply stream = do
    h0 <- _waitHeaders stream
    msg <- fmap f (_waitData stream)
    h1 <- _waitHeaders stream
    return (h0, h1, msg)
  where
    f (hdrs, dat) = (hdrs, fmap decodeResult dat)

call :: (RPC rpc)
     => rpc
     -> Http2Client
     -> Input rpc
     -> IO (Either TooMuchConcurrency (Reply (Output rpc)))
call rpc conn req = do
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", "localhost")
                  , (":path", path rpc)
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
