{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}

-- | Set of helpers helping with writing gRPC clients with not much exposure of
-- the http2-client complexity.
--
-- Th
module Network.GRPC.Client.Helpers where

import Control.Exception (throwIO)
import qualified Data.ByteString.Char8 as ByteString
import Data.ByteString.Char8 (ByteString)
import Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..), StreamingType(..))
import qualified Network.TLS as TLS
import Network.HPACK (HeaderList)

import Network.HTTP2
import Network.HTTP2.Client
import Network.GRPC.Client
import Network.GRPC.HTTP2.Types

-- | A simplified gRPC Client connected via an HTTP2Client to a given server.
-- Each call from one client will share similar headers, timeout, compression.
data GrpcClient = GrpcClient {
    _grpcClientHttp2Client :: Http2Client
  -- ^ Underlying HTTP2 client.
  , _grpcClientAuthority   :: Authority
  -- ^ Authority header of the server the client is connected to.
  , _grpcClientHeaders     :: [(ByteString, ByteString)]
  -- ^ Extra HTTP2 headers to pass to every call (e.g., authentication tokens).
  , _grpcClientTimeout     :: Timeout
  -- ^ Timeout for RPCs.
  , _grpcClientCompression :: Compression
  -- ^ Compression shared for every call and expected for every answer.
  }

-- | Configuration to setup a GrpcClient.
data GrpcClientConfig = GrpcClientConfig {
    _grpcClientConfigHost            :: !HostName
  -- ^ Hostname of the server.
  , _grpcClientConfigPort            :: !PortNumber
  -- ^ Port of the server.
  , _grpcClientConfigHeaders         :: ![(ByteString, ByteString)]
  -- ^ Extra HTTP2 headers to pass to every call (e.g., authentication tokens).
  , _grpcClientConfigTimeout         :: !Timeout
  -- ^ Timeout for RPCs.
  , _grpcClientConfigCompression     :: !Compression
  -- ^ Compression shared for every call and expected for every answer.
  , _grpcClientConfigTLS             :: !(Maybe TLS.ClientParams)
  -- ^ TLS parameters for the session.
  , _grpcClientConfigGoAwayHandler   :: GoAwayHandler
  -- ^ HTTP2 handler for GoAways.
  , _grpcClientConfigFallbackHandler :: FallBackFrameHandler
  -- ^ HTTP2 handler for unhandled frames.
  }

grpcClientConfigSimple :: HostName -> PortNumber -> GrpcClientConfig
grpcClientConfigSimple host port =
    GrpcClientConfig host port [] (Timeout 3000) gzip Nothing throwIO ignoreFallbackHandler

setupGrpcClient :: GrpcClientConfig -> IO GrpcClient
setupGrpcClient config = do
  let host = _grpcClientConfigHost config
  let port = _grpcClientConfigPort config
  let tls = _grpcClientConfigTLS config
  let compression = _grpcClientConfigCompression config
  let onGoAway = _grpcClientConfigGoAwayHandler config
  let onFallback = _grpcClientConfigFallbackHandler config
  let timeout = _grpcClientConfigTimeout config
  let headers = _grpcClientConfigHeaders config
  let authority = ByteString.pack $ host <> ":" <> show port

  conn <- newHttp2FrameConnection host port tls
  cli <- newHttp2Client conn 8192 8192 [] onGoAway onFallback
  return $ GrpcClient cli authority headers timeout compression 

rawUnary
  :: (Service s, HasMethod s m)
  => RPC s m
  -> GrpcClient
  -> MethodInput s m
  -> IO (Either TooMuchConcurrency (RawReply (MethodOutput s m)))
rawUnary rpc (GrpcClient client authority headers timeout compression) input =
    let call = singleRequest rpc compression input
    in open client authority headers timeout compression call

rawStreamServer 
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ServerStreaming)
  => RPC s m
  -> GrpcClient
  -> a
  -> MethodInput s m
  -> (a -> HeaderList -> MethodOutput s m -> IO a)
  -> IO (Either TooMuchConcurrency (a, HeaderList, HeaderList))
rawStreamServer rpc (GrpcClient client authority headers timeout compression) v0 input handler =
    let call = streamReply rpc compression v0 input handler
    in open client authority headers timeout compression call

rawStreamClient
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ClientStreaming)
  => RPC s m
  -> GrpcClient
  -> a
  -> (a -> IO (Compression, a, Either StreamDone (MethodInput s m)))
  -> IO (Either TooMuchConcurrency (a, (RawReply (MethodOutput s m))))
rawStreamClient rpc (GrpcClient client authority headers timeout compression) v0 getNext =
    let call = streamRequest rpc v0 getNext
    in open client authority headers timeout compression call
