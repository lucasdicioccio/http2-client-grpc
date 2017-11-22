{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Network.GRPC (RPC(..), ClientStream, ServerStream, call, Reply, Authority, open, RPCCall(..), singleRequest, streamReply, streamRequest, StreamDone(..)) where

import Control.Exception (Exception(..), throwIO)
import Control.Monad (forever)
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

class ClientStream n where

class ServerStream n where
  
sendMessage :: (Show a, Message a) => Http2Client -> Http2Stream -> FlagSetter -> a -> IO ()
sendMessage conn stream flagmod msg = do
    sendData conn stream flagmod (toStrict . toLazyByteString $ encodePlainMessage msg)
  where
    encodePlainMessage plain =
        let bin = encodeMessage plain
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
type Reply a = Either ErrorCode (HeaderList, Maybe HeaderList, (Either String a))

data UnallowedPushPromiseReceived = UnallowedPushPromiseReceived deriving Show
instance Exception UnallowedPushPromiseReceived where

throwOnPushPromise :: PushPromiseHandler
throwOnPushPromise _ _ _ _ _ = throwIO UnallowedPushPromiseReceived

waitReply :: Message a => Http2Stream -> IncomingFlowControl -> IO (Reply a)
waitReply stream flowControl = do
    f . fromStreamResult <$> waitStream stream flowControl throwOnPushPromise
  where
    f :: Message a => Either ErrorCode StreamResponse -> Reply a
    f rsp = do
       (hdrs, dat, trls) <- rsp
       return (hdrs, trls, decodeResult dat)

data InvalidState = InvalidState String deriving Show
instance Exception InvalidState where

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
            handler isfc _ = do
                sendMessage conn stream setEndStream req
                waitReply stream isfc                

        in StreamDefinition initStream handler

newtype RPCCall rpc a = RPCCall {
    runRPC :: rpc 
           -> Http2Client
           -> IncomingFlowControl
           -> OutgoingFlowControl
           -> Http2Stream
           -> IncomingFlowControl
           -> OutgoingFlowControl
           -> IO a
  }

-- | Call and wait (possibly forever for now) for a reply.
open :: RPC rpc
     => Http2Client
     -- ^ A connected HTTP2 client.
     -> IncomingFlowControl
     -- ^ The connection incoming flow control.
     -> OutgoingFlowControl
     -- ^ The connection outgoing flow control.
     -> Authority
     -- ^ The HTTP2-Authority portion of the URL (e.g., "dicioccio.fr:7777").
     -> HeaderList
     -- ^ A set of HTTP2 headers (e.g., for adding authentication headers).
     -> rpc
     -- ^ The RPC to call.
     -> RPCCall rpc a
     -- ^ The actual RPC handler.
     -> IO (Either TooMuchConcurrency a)
open conn icfc ocfc authority extraheaders rpc doStuff = do
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
                (runRPC doStuff) rpc conn icfc ocfc stream isfc osfc
        in StreamDefinition initStream handler

streamReply :: (Message (Output n), ServerStream n)
            => (HeaderList -> Either String (Output n) -> IO ())
            -> RPCCall n (HeaderList, HeaderList)
streamReply handler = RPCCall $ \_ _ _ _ stream flowControl _ -> do
    let {
        loop hdrs = _waitEvent stream >>= \case
            (StreamPushPromiseEvent _ _ _) ->
                throwIO (InvalidState "push promise")
            (StreamHeadersEvent _ trls) ->
                return (hdrs, trls)
            (StreamErrorEvent _ _) ->
                throwIO (InvalidState "stream error")
            (StreamDataEvent _ dat) -> do
                _addCredit flowControl (ByteString.length dat)
                _ <- _consumeCredit flowControl (ByteString.length dat)
                _ <- _updateWindow flowControl
                handler hdrs (decodeResult dat)
                loop hdrs
    } in
        _waitEvent stream >>= \case
            StreamHeadersEvent _ hdrs ->
                loop hdrs
            _                         ->
                throwIO (InvalidState "no headers")

data StreamDone = StreamDone

streamRequest :: (Message (Input n), ClientStream n)
              => (IO (Either StreamDone (Input n)))
              -> RPCCall n ()
streamRequest handler = RPCCall $ \_ conn _ connectionFlowControl stream _ streamFlowControl -> do
    forever $ do
        nextEvent <- handler
        case nextEvent of
            Right msg ->
                sendSingleMessage msg id conn connectionFlowControl stream streamFlowControl
            Left _ ->
                sendData conn stream setEndStream ""

sendSingleMessage :: Message a
                  => a
                  -> FlagSetter
                  -> Http2Client
                  -> OutgoingFlowControl
                  -> Http2Stream
                  -> OutgoingFlowControl
                  -> IO ()
sendSingleMessage msg flagMod conn connectionFlowControl stream streamFlowControl = do
    let goUpload dat = do
            let !wanted = ByteString.length dat
            gotStream <- _withdrawCredit streamFlowControl wanted
            got       <- _withdrawCredit connectionFlowControl gotStream
            _receiveCredit streamFlowControl (gotStream - got)
            if got == wanted
            then
                sendData conn stream flagMod dat
            else do
                sendData conn stream id (ByteString.take got dat)
                goUpload (ByteString.drop got dat)
    goUpload . toStrict . toLazyByteString . encodePlainMessage $ msg
  where
    encodePlainMessage plain =
        let bin = encodeMessage plain
        in singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin

singleRequest :: (Message (Input n), Message (Output n))
              => Input n
              -> RPCCall n (Reply (Output n))
singleRequest msg = RPCCall $ \_ conn _ ocfc stream isfc osfc -> do
    sendSingleMessage msg setEndStream conn ocfc stream osfc
    waitReply stream isfc
