{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Network.GRPC (RPC(..), call, Reply, Authority) where

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
  
sendMessage :: (Show a, Message a) => Http2Client -> Http2Stream -> FlagSetter -> a -> IO ()
sendMessage conn stream flagmod msg = do
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

-- | A reply.
--
-- This reply object contains a lot of information because a single gRPC call
-- returns a lot of data. A future version of the library will have a proper
-- data structure with properly named-fields on the reply object.
--
-- For now, remember:
-- - 1st item: initial HTTP2 response
-- - 2nd item: second (trailers) HTTP2 response
-- - 3rd item: proper gRPC answer
type Reply a = ((FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, StreamId, Either ErrorCode HeaderList),
                (FrameHeader, Either ErrorCode (Either String a)))

waitReply :: Message a => Http2Stream -> IO (Reply a)
waitReply stream = do
    h0 <- _waitHeaders stream
    msg <- f <$> _waitData stream
    h1 <- _waitHeaders stream
    return (h0, h1, msg)
  where
    f (hdrs, dat) = (hdrs, fmap decodeResult dat)

-- | The HTTP2-Authority portion of an URL (e.g., "dicioccio.fr:7777").
type Authority = ByteString.ByteString

-- | Call and wait (possibly forever for now) for a reply.
call :: (Show (Input rpc), RPC rpc)
     => Http2Client
     -- ^ A connected HTTP2 client.
     -> Authority
     -- ^ The HTTP2-Authority portion of the URL (e.g., "dicioccio.fr:7777").
     -> HeaderList
     -- ^ A set of HTTP2 headers (e.g., for adding authentication headers).
     -> rpc
     -- ^ The RPC you want to call (for instance, Greeter_SayHello).
     -> Input rpc
     -- ^ The RPC input message.
     -> IO (Either TooMuchConcurrency (Reply (Output rpc)))
call conn authority extraheaders rpc req = do
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", authority)
                  , (":path", path rpc)
                  , ("grpc-timeout", "1S")
                  , ("content-type", "application/grpc+proto")
                  , ("te", "trailers")
                  ] <> extraheaders
    withHttp2Stream conn $ \stream ->
        let
            initStream = headers stream request (setEndHeader)
            handler isfc osfc = do
                sendMessage conn stream setEndStream req
                waitReply stream 
        in StreamDefinition initStream handler
