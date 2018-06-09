{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | A module adding support for gRPC over HTTP2.
module Network.GRPC (
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

import qualified Codec.Compression.GZip as GZip
import Control.Exception (Exception(..), throwIO)
import Control.Monad (forever)
import Data.Proxy (Proxy(..))
import Data.Monoid ((<>))
import Data.ByteString.Char8 (ByteString, pack, unpack)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Binary.Builder (toLazyByteString, fromByteString, singleton, putWord32be)
import Data.Binary.Get (Decoder(..), getByteString, getInt8, getWord32be, pushChunk, pushEndOfInput, runGetIncremental)
import qualified Data.ByteString.Char8 as ByteString
import Data.ProtoLens.Encoding (encodeMessage, decodeMessage)
import Data.ProtoLens.Message (Message)
import Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..), StreamingType(..))
import GHC.TypeLits (Symbol, symbolVal)

import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

-- | A proxy type for giving static information about RPCs.
data RPC (s :: *) (m :: Symbol) = RPC

-- | Returns the HTTP2 :path for a given RPC.
path :: (Service s, HasMethod s m) => RPC s m -> ByteString
path rpc = "/" <> pkg rpc Proxy <> "." <> srv rpc Proxy <> "/" <> meth rpc Proxy
  where
    pkg :: (Service s) => RPC s m -> Proxy (ServicePackage s) -> ByteString
    pkg _ p = pack $ symbolVal p

    srv :: (Service s) => RPC s m -> Proxy (ServiceName s) -> ByteString
    srv _ p = pack $ symbolVal p

    meth :: (Service s, HasMethod s m) => RPC s m -> Proxy (MethodName s m) -> ByteString
    meth _ p = pack $ symbolVal p

-- | Decodes a method's output.
decodeResult :: (Service s, HasMethod s m) => RPC s m -> Decoder (Either String (MethodOutput s m))
decodeResult _ = runGetIncremental $ do
    isCompressed <- getInt8      -- 1byte
    let compression = if isCompressed == 0 then id else (toStrict . GZip.decompress . fromStrict)
    n <- getWord32be  -- 4bytes
    decodeMessage . compression <$> getByteString (fromIntegral n)

-- | Tries finalizing a Decoder.
fromDecoder :: Decoder (Either String a) -> Either String a
fromDecoder (Fail _ _ msg) = Left msg
fromDecoder (Partial _)    = Left "got only a subet of the message"
fromDecoder (Done _ _ val) = val

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
waitReply :: (Service s, HasMethod s m) => RPC s m -> Http2Stream -> IncomingFlowControl -> IO (RawReply (MethodOutput s m))
waitReply rpc stream flowControl = do
    format . fromStreamResult <$> waitStream stream flowControl throwOnPushPromise
  where
    format rsp = do
       (hdrs, dat, trls) <- rsp
       let res =
             case lookup "grpc-message" hdrs of
               Nothing     -> fromDecoder $ pushEndOfInput $ flip pushChunk dat $ decodeResult rpc
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

-- | The HTTP2-Authority portion of an URL (e.g., "dicioccio.fr:7777").
type Authority = ByteString.ByteString

-- | Newtype helper used to uniformize all type of streaming modes when
-- passing arguments to the 'open' call.
newtype RPCCall a = RPCCall {
    runRPC :: Http2Client -> Http2Stream -> IncomingFlowControl -> OutgoingFlowControl -> IO a
  }

-- | Timeout in seconds.
newtype Timeout = Timeout Int

showTimeout :: Timeout -> ByteString.ByteString
showTimeout (Timeout n) = ByteString.pack $ show n ++ "S"

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
     -- ^ An indication of the compression that you will be using.  Compression
     -- should be per message, however a bug in gRPC-Go (to be confirmed) seems
     -- to turn message compression mandatory if advertised in the HTTP2
     -- headers, even though the specification states that compression per
     -- message is optional irrespectively of headers.
     -> RPCCall a
     -- ^ The actual RPC handler.
     -> IO (Either TooMuchConcurrency a)
open rpc conn authority extraheaders timeout compression doStuff = do
    let icfc = _incomingFlowControl conn
    let ocfc = _outgoingFlowControl conn
    let request = [ (":method", "POST")
                  , (":scheme", "http")
                  , (":authority", authority)
                  , (":path", path rpc) 
                  , ("grpc-timeout", showTimeout timeout)
                  , ("grpc-encoding", _compressionName compression)
                  , ("grpc-accept-encoding", "identity,gzip")
                  , ("content-type", "application/grpc+proto")
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
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ ServerStreaming)
  => RPC s m
  -> Compression
  -> MethodInput s m
  -> (HeaderList -> Either String (MethodOutput s m) -> IO ())
  -> RPCCall (HeaderList, HeaderList)
streamReply rpc compress req handler = RPCCall $ \conn stream isfc osfc -> do
    let {
        loop decoder hdrs = _waitEvent stream >>= \case
            (StreamPushPromiseEvent _ _ _) ->
                throwIO (InvalidState "push promise")
            (StreamHeadersEvent _ trls) ->
                return (hdrs, trls)
            (StreamErrorEvent _ _) ->
                throwIO (InvalidState "stream error")
            (StreamDataEvent _ dat) -> do
                _addCredit isfc (ByteString.length dat)
                _ <- _consumeCredit isfc (ByteString.length dat)
                _ <- _updateWindow isfc
                handleAllChunks hdrs decoder dat loop
    } in do
        let ocfc = _outgoingFlowControl conn
        sendSingleMessage req compress setEndStream conn ocfc stream osfc
        _waitEvent stream >>= \case
            StreamHeadersEvent _ hdrs ->
                loop (decodeResult rpc) hdrs
            _                         ->
                throwIO (InvalidState "no headers")
  where
    handleAllChunks hdrs decoder dat exitLoop =
       case pushChunk decoder dat of
           (Done unusedDat _ val) -> do
               handler hdrs val
               handleAllChunks hdrs (decodeResult rpc) unusedDat exitLoop
           failure@(Fail _ _ err)   -> do
               handler hdrs (fromDecoder failure)
               throwIO (StreamReplyDecodingError err)
           partial@(Partial _)    ->
               exitLoop partial hdrs

data StreamDone = StreamDone

-- | gRPC call for Client Streaming.
streamRequest
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ ClientStreaming)
  => RPC s m
  -> (IO (Either StreamDone (MethodInput s m, Compression)))
  -> RPCCall (RawReply (MethodOutput s m))
streamRequest rpc handler = RPCCall $ \conn stream isfc streamFlowControl ->
    let ocfc = _outgoingFlowControl conn
        go = do
            nextEvent <- handler
            case nextEvent of
                Right (msg, compress) -> do
                    sendSingleMessage msg compress id conn ocfc stream streamFlowControl
                    go
                Left _ -> do
                    sendData conn stream setEndStream ""
                    waitReply rpc stream isfc
    in go


-- | Serialize and send a single message.
sendSingleMessage :: Message a
                  => a
                  -> Compression
                  -> FlagSetter
                  -> Http2Client
                  -> OutgoingFlowControl
                  -> Http2Stream
                  -> OutgoingFlowControl
                  -> IO ()
sendSingleMessage msg compression flagMod conn connectionFlowControl stream streamFlowControl = do
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
    compressedByte = if _compressionByteSet compression then 1 else 0
    compressMethod = _compressionFunction compression
    encodePlainMessage plain =
        let bin = encodeMessage plain
        in singleton compressedByte <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString (compressMethod $ bin)

-- | gRPC call for an unary request.
singleRequest
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> MethodInput s m
  -> RPCCall (RawReply (MethodOutput s m))
singleRequest rpc compress msg = RPCCall $ \conn stream isfc osfc -> do
    let ocfc = _outgoingFlowControl conn
    sendSingleMessage msg compress setEndStream conn ocfc stream osfc
    waitReply rpc stream isfc

-- | Opaque type for handling compression.
--
-- So far, only "pure" compression algorithms are supported.
-- TODO: suport IO-based compression implementations.
data Compression = Compression {
    _compressionName    :: ByteString.ByteString
  , _compressionByteSet :: Bool
  , _compressionFunction :: (ByteString.ByteString -> ByteString.ByteString)
  }

-- | Use gzip as compression.
gzip :: Compression
gzip = Compression "gzip" True (toStrict . GZip.compress . fromStrict)

-- | Do not compress.
uncompressed :: Compression
uncompressed = Compression "identity" False id
