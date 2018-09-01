{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}

-- | Set of helpers helping with writing gRPC clients with not much exposure of
-- the http2-client complexity.
--
-- The GrpcClient handles automatic background connection-level window updates
-- to prevent the connection from starving and pings to force a connection
-- alive.
--
-- There is no automatic reconnection, retry, or healthchecking. These features
-- are not planned in this library and should be added at higher-levels.
module Network.GRPC.Client.Helpers where

import Control.Concurrent.Async (Async, async)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (forever)
import qualified Data.ByteString.Char8 as ByteString
import Data.ByteString.Char8 (ByteString)
import Data.Default.Class (def)
import Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..), StreamingType(..))
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import Network.HPACK (HeaderList)

import Network.HTTP2
import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers (ping)
import Network.GRPC.Client
import Network.GRPC.HTTP2.Types
import Network.GRPC.HTTP2.Encoding

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
  , _grpcClientBackground  :: BackgroundTasks
  -- ^ Running background tasks.
  }

data BackgroundTasks = BackgroundTasks {
    backgroundWindowUpdate :: Async ()
  -- ^ Periodically give the server credit to use the connection.
  , backgroundPing         :: Async ()
  -- ^ Periodically ping the server.
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
  , _grpcClientConfigTLS             :: !(Maybe ClientParams)
  -- ^ TLS parameters for the session.
  , _grpcClientConfigGoAwayHandler   :: GoAwayHandler
  -- ^ HTTP2 handler for GoAways.
  , _grpcClientConfigFallbackHandler :: FallBackFrameHandler
  -- ^ HTTP2 handler for unhandled frames.
  , _grpcClientConfigWindowUpdateDelay :: Int
  -- ^ Delay in microsecond between to window updates.
  , _grpcClientConfigPingDelay         :: Int
  -- ^ Delay in microsecond between to pings.
  }

grpcClientConfigSimple :: HostName -> PortNumber -> UseTlsOrNot -> GrpcClientConfig
grpcClientConfigSimple host port tls =
    GrpcClientConfig host port [] (Timeout 3000) gzip (tlsSettings tls host port) throwIO ignoreFallbackHandler 5000000 1000000

type UseTlsOrNot = Bool

tlsSettings :: UseTlsOrNot -> HostName -> PortNumber -> Maybe ClientParams
tlsSettings False _ _ = Nothing
tlsSettings True host port = Just $ TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = (host, ByteString.pack $ show port)
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }


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
  wuAsync <- async $ forever $ do
      threadDelay $ _grpcClientConfigWindowUpdateDelay config
      _updateWindow $ _incomingFlowControl cli
  pingAsync <- async $ forever $ do
      threadDelay $ _grpcClientConfigPingDelay config
      ping cli 3000000 "grpc.hs"
  let tasks = BackgroundTasks wuAsync pingAsync
  return $ GrpcClient cli authority headers timeout compression tasks

rawUnary
  :: (Service s, HasMethod s m)
  => RPC s m
  -> GrpcClient
  -> MethodInput s m
  -> IO (Either TooMuchConcurrency (RawReply (MethodOutput s m)))
rawUnary rpc (GrpcClient client authority headers timeout compression _) input =
    let call = singleRequest rpc input
    in open client authority headers timeout (Encoding compression) (Decoding compression) call

rawStreamServer 
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ServerStreaming)
  => RPC s m
  -> GrpcClient
  -> a
  -> MethodInput s m
  -> (a -> HeaderList -> MethodOutput s m -> IO a)
  -> IO (Either TooMuchConcurrency (a, HeaderList, HeaderList))
rawStreamServer rpc (GrpcClient client authority headers timeout compression _) v0 input handler =
    let call = streamReply rpc v0 input handler
    in open client authority headers timeout (Encoding compression) (Decoding compression) call

rawStreamClient
  :: (Service s, HasMethod s m, MethodStreamingType s m ~ 'ClientStreaming)
  => RPC s m
  -> GrpcClient
  -> a
  -> (a -> IO (a, Either StreamDone (CompressMode, MethodInput s m)))
  -> IO (Either TooMuchConcurrency (a, (RawReply (MethodOutput s m))))
rawStreamClient rpc (GrpcClient client authority headers timeout compression _) v0 getNext =
    let call = streamRequest rpc v0 getNext
    in open client authority headers timeout (Encoding compression) (Decoding compression) call
