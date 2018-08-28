{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | A module adding support for gRPC over HTTP2.
module Network.GRPC.Client (
  -- * Building blocks.
    RPC(..)
  , Authority
  , Timeout(..)
  , open
  , RawReply
  -- * Helpers
  , singleRequest
  , streamReply
  , streamRequest
  , StreamDone(..)
  -- * Errors.
  , InvalidState(..)
  , StreamReplyDecodingError(..)
  , UnallowedPushPromiseReceived(..)
  -- * Compression of individual messages.
  , Compression
  , gzip
  , uncompressed
  ) where

import Control.Exception (Exception(..), throwIO)
import Data.Monoid ((<>))
import Data.ByteString.Char8 (unpack)
import Data.ByteString.Lazy (toStrict)
import Data.Binary.Builder (toLazyByteString)
import Data.Binary.Get (Decoder(..), pushChunk, pushEndOfInput)
import qualified Data.ByteString.Char8 as ByteString
import Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..), StreamingType(..))

import Network.GRPC.HTTP2.Types
import Network.GRPC.HTTP2.Encoding
import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

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
type RawReply a = Either ErrorCode (HeaderList, Maybe HeaderList, (Either String a))

-- | gRPC disables HTTP2 push-promises.
--
-- If a server attempts to send push-promises, this exception will be raised.
data UnallowedPushPromiseReceived = UnallowedPushPromiseReceived deriving Show
instance Exception UnallowedPushPromiseReceived where

-- | http2-client handler for push promise.
throwOnPushPromise :: PushPromiseHandler
throwOnPushPromise _ _ _ _ _ = throwIO UnallowedPushPromiseReceived

-- | Wait for an RPC reply.
waitReply :: (Service s, HasMethod s m) => RPC s m -> Compression -> Http2Stream -> IncomingFlowControl -> IO (RawReply (MethodOutput s m))
waitReply rpc compress stream flowControl = do
    format . fromStreamResult <$> waitStream stream flowControl throwOnPushPromise
  where
    format rsp = do
       (hdrs, dat, trls) <- rsp
       let res =
             case lookup grpcMessageH hdrs of
               Nothing     -> fromDecoder $ pushEndOfInput $ flip pushChunk dat $ decodeOutput rpc compress
               Just errMsg -> Left $ unpack errMsg

       return (hdrs, trls, res)

-- | Exception raised when a ServerStreaming RPC results in a decoding
-- error.
data StreamReplyDecodingError = StreamReplyDecodingError String deriving Show
instance Exception StreamReplyDecodingError where

-- | Exception raised when a ServerStreaming RPC results in an invalid
-- state machine.
data InvalidState = InvalidState String deriving Show
instance Exception InvalidState where

-- | Newtype helper used to uniformize all type of streaming modes when
-- passing arguments to the 'open' call.
newtype RPCCall a = RPCCall {
    runRPC :: Http2Client -> Http2Stream -> IncomingFlowControl -> OutgoingFlowControl -> IO a
  }

-- | Main handler to perform gRPC calls to a service.
open :: (Service s, HasMethod s m)
     => RPC s m
     -- ^ A token carrying information specifying the RPC to call.
     -> Http2Client
     -- ^ A connected HTTP2 client.
     -> Authority
     -- ^ The HTTP2-Authority portion of the URL (e.g., "dicioccio.fr:7777").
     -> HeaderList
     -- ^ A set of HTTP2 headers (e.g., for adding authentication headers).
     -> Timeout
     -- ^ Timeout in seconds.
     -> Compression
     -- ^ An indication of the compression that you will be using and accepting.  Compression
     -- should be per message, however a bug in gRPC-Go (to be confirmed) seems
     -- to turn message compression mandatory if advertised in the HTTP2
     -- headers, even though the specification states that compression per
     -- message is optional irrespectively of headers.
     -> RPCCall a
     -- ^ The actual RPC handler.
     -> IO (Either TooMuchConcurrency a)
open rpc conn authority extraheaders timeout compression doStuff = do
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", authority)
                  , (":path", path rpc) 
                  , (grpcTimeoutH, showTimeout timeout)
                  , (grpcEncodingH, grpcCompressionHV compression)
                  , (grpcAcceptEncodingH, mconcat [grpcAcceptEncodingHVdefault, ",", grpcCompressionHV compression])
                  , ("content-type", grpcContentTypeHV)
                  , ("te", "trailers")
                  ] <> extraheaders
    withHttp2Stream conn $ \stream ->
        let
            initStream = headers stream request (setEndHeader)
            handler isfc osfc = do
                (runRPC doStuff) conn stream isfc osfc
        in StreamDefinition initStream handler

-- | gRPC call for Server Streaming.
streamReply
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ServerStreaming)
  => RPC s m
  -- ^ The RPC to call.
  -> Compression
  -- ^ The compression to use.
  -- TODO: revisit compressions.
  -> a
  -- ^ An initial state.
  -> MethodInput s m
  -- ^ The input.
  -> (a -> HeaderList -> MethodOutput s m -> IO a)
  -- ^ A state-passing handler that is called with the message read.
  -> RPCCall (a, HeaderList, HeaderList)
streamReply rpc compress v0 req handler = RPCCall $ \conn stream isfc osfc -> do
    let {
        loop v1 decode hdrs = _waitEvent stream >>= \case
            (StreamPushPromiseEvent _ _ _) ->
                throwIO (InvalidState "push promise")
            (StreamHeadersEvent _ trls) ->
                return (v1, hdrs, trls)
            (StreamErrorEvent _ _) ->
                throwIO (InvalidState "stream error")
            (StreamDataEvent _ dat) -> do
                _addCredit isfc (ByteString.length dat)
                _ <- _consumeCredit isfc (ByteString.length dat)
                _ <- _updateWindow isfc
                handleAllChunks v1 hdrs decode dat loop
    } in do
        let ocfc = _outgoingFlowControl conn
        sendSingleMessage rpc req compress setEndStream conn ocfc stream osfc
        _waitEvent stream >>= \case
            StreamHeadersEvent _ hdrs ->
                loop v0 (decodeOutput rpc compress) hdrs
            _                         ->
                throwIO (InvalidState "no headers")
  where
    handleAllChunks v1 hdrs decode dat exitLoop =
       case pushChunk decode dat of
           (Done unusedDat _ (Right val)) -> do
               v2 <- handler v1 hdrs val
               handleAllChunks v2 hdrs (decodeOutput rpc compress) unusedDat exitLoop
           (Done unusedDat _ (Left err)) -> do
               throwIO (StreamReplyDecodingError $ "done-error: " ++ err)
           (Fail _ _ err)                 -> do
               throwIO (StreamReplyDecodingError $ "fail-error: " ++ err)
           partial@(Partial _)    ->
               exitLoop v1 partial hdrs

data StreamDone = StreamDone

-- | gRPC call for Client Streaming.
streamRequest
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ClientStreaming)
  => RPC s m
  -- ^ RPC to call.
  -> a
  -- ^ An initial state.
  -> (a -> IO (Compression, a, Either StreamDone (MethodInput s m)))
  -- ^ A state-passing action to retrieve the next message to send to the server.
  -> RPCCall (a, RawReply (MethodOutput s m))
streamRequest rpc v0 handler = RPCCall $ \conn stream isfc streamFlowControl ->
    let ocfc = _outgoingFlowControl conn
        go v1 = do
            (compress, v2, nextEvent) <- handler v1
            case nextEvent of
                Right msg -> do
                    sendSingleMessage rpc msg compress id conn ocfc stream streamFlowControl
                    go v2
                Left _ -> do
                    sendData conn stream setEndStream ""
                    reply <- waitReply rpc compress stream isfc
                    pure (v2, reply)
    in go v0


-- | Serialize and send a single message.
sendSingleMessage
  :: (Service s, HasMethod s m)
  => RPC s m
  -> MethodInput s m
  -> Compression
  -> FlagSetter
  -> Http2Client
  -> OutgoingFlowControl
  -> Http2Stream
  -> OutgoingFlowControl
  -> IO ()
sendSingleMessage rpc msg compression flagMod conn connectionFlowControl stream streamFlowControl = do
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
    goUpload . toStrict . toLazyByteString . encodeInput rpc compression $ msg

-- | gRPC call for an unary request.
singleRequest
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> MethodInput s m
  -> RPCCall (RawReply (MethodOutput s m))
singleRequest rpc compress msg = RPCCall $ \conn stream isfc osfc -> do
    let ocfc = _outgoingFlowControl conn
    sendSingleMessage rpc msg compress setEndStream conn ocfc stream osfc
    waitReply rpc compress stream isfc
