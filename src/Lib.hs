{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
module Lib
    ( someFunc
    ) where

import Data.Default.Class (def)
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher as TLS

import Network.GRPC
import Network.HTTP2.Client
import Proto.Helloworld
import GRPC.Helloworld

someFunc :: IO ()
someFunc = do
    conn <- newHttp2Client "127.0.0.1" 50051 8192 8192 tlsParams []

    let ifc = _incomingFlowControl conn
    let ofc = _outgoingFlowControl conn
    _addCredit ifc 1000000
    _ <- _updateWindow ifc
    print =<< (call Greeter_SayHello conn (HelloRequest "world")  :: IO (Either TooMuchConcurrency (Reply HelloReply)))
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
