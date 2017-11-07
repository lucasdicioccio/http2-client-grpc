{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Main where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Map.Strict ((!))
import Data.Monoid ((<>))
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text, pack)
import Data.ProtoLens (decodeMessage, def, encodeMessage)
import Lens.Family2
import Proto.Google.Protobuf.Compiler.Plugin
    ( CodeGeneratorRequest
    , CodeGeneratorResponse
    )
import Proto.Google.Protobuf.Compiler.Plugin'Fields
    ( file
    , name
    , content
    , fileToGenerate
    , parameter
    , protoFile
    )
import Data.ProtoLens.Compiler.Definitions
    ( Env
    )
import Proto.Google.Protobuf.Descriptor
    ( FileDescriptorProto
    , ServiceDescriptorProto
    , MethodDescriptorProto
    )
import Proto.Google.Protobuf.Descriptor'Fields
    ( dependency
    , service
    , method
    , package
    , inputType
    , outputType
    , clientStreaming
    , serverStreaming
    )
import System.Environment (getProgName)
import System.Exit (exitWith, ExitCode(..))
import System.IO as IO

import Data.ProtoLens.Compiler.Combinators (prettyPrint, getModuleName)
import Data.ProtoLens.Compiler.Generate
import Data.ProtoLens.Compiler.Plugin

import qualified Language.Haskell.Exts.Syntax as Syntax

main :: IO ()
main = do
    contents <- B.getContents
    progName <- getProgName
    case decodeMessage contents of
        Left e -> IO.hPutStrLn stderr e >> exitWith (ExitFailure 1)
        Right x -> do
            let rsp = makeResponse progName x
            B.putStr $ encodeMessage $ rsp

makeResponse :: String -> CodeGeneratorRequest -> CodeGeneratorResponse
makeResponse prog request = let
    outputFiles = generateFiles header
                      (request ^. protoFile)
                      (request ^. fileToGenerate)
    header :: FileDescriptorProto -> Text
    header f = "{- This file was auto-generated from "
                <> (f ^. name)
                <> " by the " <> pack prog <> " program. -}\n"
    in def & file .~ [ def & name .~ outputName
                           & content .~ outputContent
                     | (outputName, outputContent) <- outputFiles
                     ]

generateFiles :: (FileDescriptorProto -> Text)
              -> [FileDescriptorProto] -> [ProtoFileName] -> [(Text, Text)]
generateFiles header files toGenerate = let
  modulePrefix = "GRPC"
  protofilesByName = analyzeProtoFiles "Proto" files
  filesByName = analyzeProtoFiles modulePrefix files
  -- The contents of the generated Haskell file for a given .proto file.
  modulesToBuild f protoF = let
      deps = descriptor f ^. dependency
      imports = [ haskellModule protoF ]
      in [ makeModule f imports ]
  in [ ( outputFilePath $ prettyPrint modName
       , header (descriptor f) <> pack (prettyPrint modul)
       )
     | fileName <- toGenerate
     , let (f, protoF) = (filesByName ! fileName, protofilesByName ! fileName)
     , modul <- modulesToBuild f protoF
     , let Just modName =  getModuleName modul
     ]

makeModule :: ProtoFile -> [Syntax.ModuleName ()] -> Syntax.Module ()
makeModule pf externimports =
    Syntax.Module () (Just $ Syntax.ModuleHead () modName Nothing Nothing) pragmas imports decls
  where
    modName = haskellModule pf
    desc    = descriptor pf

    pragmas :: [Syntax.ModulePragma ()]
    pragmas = [ Syntax.LanguagePragma () [ Syntax.Ident () ext ] | ext <- [
                  "OverloadedStrings"
                , "TypeFamilies"
                ]
              ]

    imports :: [Syntax.ImportDecl ()]
    imports = baseImports ++ [ Syntax.ImportDecl () externimport False False False Nothing Nothing Nothing | externimport <- externimports ]
 
    baseImports :: [Syntax.ImportDecl ()]
    baseImports = [ Syntax.ImportDecl () "Network.GRPC" False False False Nothing Nothing Nothing ]

    services = desc ^. service

    decls :: [Syntax.Decl ()]
    decls = mconcat [ rpcDecl service meth | service <- services , meth <- service ^. method ]

    rpcDecl :: ServiceDescriptorProto -> MethodDescriptorProto -> [Syntax.Decl ()]
    rpcDecl service method = [ rpcDataDecl service method
                             , rpcInstanceDecl service method
                             ] ++ rpcStreamingDecls service method
    rpcDataDecl :: ServiceDescriptorProto -> MethodDescriptorProto -> Syntax.Decl ()
    rpcDataDecl service method =
        Syntax.DataDecl () (Syntax.DataType ()) Nothing (Syntax.DHead () dataname) [single] Nothing
      where
        single = Syntax.QualConDecl () Nothing Nothing (Syntax.ConDecl () dataname [])
        dataname = rpcHaskellName service method

    rpcHaskellName :: ServiceDescriptorProto -> MethodDescriptorProto -> Syntax.Name ()
    rpcHaskellName service method =
        Syntax.Ident () $ T.unpack $ mconcat [ T.toTitle $ service ^. name
                                             , "_"
                                             , method ^. name
                                             ]

    rpcInputHaskellName :: MethodDescriptorProto -> Syntax.Name ()
    rpcInputHaskellName method =
        Syntax.Ident () $ T.unpack $ protoFullIdentToDatatypeName $ method ^. inputType

    rpcOutputHaskellName :: MethodDescriptorProto -> Syntax.Name ()
    rpcOutputHaskellName method =
        Syntax.Ident () $ T.unpack $ protoFullIdentToDatatypeName $ method ^. outputType

    protoFullIdentToDatatypeName :: Text -> Text
    protoFullIdentToDatatypeName = T.takeWhileEnd (\c -> c /= '.')

    rpcGrpcPath :: ServiceDescriptorProto -> MethodDescriptorProto -> String
    rpcGrpcPath service method = T.unpack $
        mconcat [ "/", desc ^. package , "." , service ^. name , "/" , method ^. name ]

    rpcInstanceDecl :: ServiceDescriptorProto -> MethodDescriptorProto -> Syntax.Decl ()
    rpcInstanceDecl service method =
        Syntax.InstDecl () Nothing
            (Syntax.IRule () Nothing Nothing
                (Syntax.IHApp ()
                    (Syntax.IHCon ()
                        (Syntax.UnQual () $ Syntax.Ident () "RPC"))
                        (Syntax.TyCon () (Syntax.UnQual () $ rpcHaskellName service method))))
            (Just [ typeFamilyRequestType , typeFamilyReplyType , pathDecl ])
      where
        typeFamilyRequestType , typeFamilyReplyType , pathDecl :: Syntax.InstDecl ()
        typeFamilyRequestType = Syntax.InsType ()
            (Syntax.TyApp ()
               (Syntax.TyCon () $ Syntax.UnQual () $ Syntax.Ident () "Input")
               (Syntax.TyCon () (Syntax.UnQual () $ rpcHaskellName service method)))
            (Syntax.TyCon () (Syntax.UnQual () $ rpcInputHaskellName method))

        typeFamilyReplyType = Syntax.InsType ()
            (Syntax.TyApp ()
               (Syntax.TyCon () $ Syntax.UnQual () $ Syntax.Ident () "Output")
               (Syntax.TyCon () (Syntax.UnQual () $ rpcHaskellName service method)))
            (Syntax.TyCon () (Syntax.UnQual () $ rpcOutputHaskellName method))

        path = rpcGrpcPath service method
        pathDecl = Syntax.InsDecl () $ Syntax.FunBind () [
            Syntax.Match () (Syntax.Ident () "path")
                            [(Syntax.PWildCard ())]
                            (Syntax.UnGuardedRhs ()
                                (Syntax.Lit () $ Syntax.String () path path))
                            Nothing
          ]
    rpcStreamingDecls :: ServiceDescriptorProto -> MethodDescriptorProto -> [Syntax.Decl ()]
    rpcStreamingDecls service method =
        let clientStream = rpcStreamingDecl "ClientStream" service method
            serverStream = rpcStreamingDecl "ServerStream" service method
        in case (method ^. clientStreaming, method ^. serverStreaming) of
          (True, True) -> [ clientStream , serverStream ]
          (True, _)    -> [ clientStream ]
          (_, True)    -> [ serverStream ]
          _            -> [ ]

    rpcStreamingDecl :: String -> ServiceDescriptorProto -> MethodDescriptorProto -> Syntax.Decl ()
    rpcStreamingDecl typeclass service method =
        Syntax.InstDecl () Nothing
            (Syntax.IRule () Nothing Nothing
                (Syntax.IHApp ()
                    (Syntax.IHCon ()
                        (Syntax.UnQual () $ Syntax.Ident () typeclass))
                        (Syntax.TyCon () (Syntax.UnQual () $ rpcHaskellName service method))))
            Nothing
