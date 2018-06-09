# http2-client-grpc

A native HTTP2 gRPC client library using `proto-lens` and `http2-client`.

## Summary

This project provides a library that leverages the code generated using
proto-lens (in particular, proto-lens-protoc) to implement the client-side of
gRPC services.

## Usage

### Prerequisites

In addition to a working Haskell dev environment, you need to:
- build the `proto-lens-protoc` executable (`proto-lens`)
- install the `protoc` executable

### Adding .proto files to a Haskell package

In order to run gRPC:

- generate the `Proto` stubs in some `gen` directory

A single `protoc` invocation may be enough for both Proto and GRPC outputs:

```bash
protoc  "--plugin=protoc-gen-haskell-protolens=${protolens}" \
    --haskell-protolens_out=./gen \
    -I "${protodir1} \
    -I "${protodir2} \
    ${first.proto} \
    ${second.proto}
```

- add the `gen` sourcedir for the generated to your .cabal/package.yaml file (cf. 'hs-source-dirs').
- add the generated Proto modules to the 'exposed-modules' (or 'other-modules') keys

A reliable way to list the module names is the following bash invocation:

```bash
find gen -name "*.hs" | sed -e 's/gen\///' | sed -e 's/\.hs$//' | tr '/' '.'
```

Unlike `proto-lens`, this project does not yet provide a modified `Setup.hs`.
As a result, we cannot automate these steps from within Cabal/Stack. Hence,
you'll have to automate these steps outside your Haskell toolchain.

## Calling a GRPC service

In short, use `http2-client` with the `Network.GRPC.call` function and let the types guide you.

### Example

You'll find an example leveraging the awesome `grpcb.in` service at https://github.com/lucasdicioccio/http2-client-grpc-example .

### gRPC service mapping

The Protobuf format specifies the notion of Service which can have one or more
RPCs.  The gRPC protocal maps these services onto HTTP2 headers and HTTP2
frames.  In general, gRPC implementation generate one inlined function per RPC.
This implementation differs by decoupling the HTTP2 transport and leveraging
generics to provide generic functions. This design allows the
`Network.GRPC.call` to be type safe and multi-usage. For instance, you can wrap
this function with whatever metrics/benchmark code and have all your RPC calls
be monitored in a uniform way.

## Status

This library is currently an early-stage library. Expect breaking changes.

## TODOs

- pass timeout as argument
- support compression
- provide function to map raw results into commonly-understood GRPC errors
