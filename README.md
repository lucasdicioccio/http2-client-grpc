# http2-client-grpc

A native HTTP2 gRPC client generator using `proto-lens` and `http2-client`.

## Summary

This project provides two things:
- an executable which is a suitable `protoc` plugin to generate stubs
- a library that the generated stubs link

## Usage

### Prerequisites

In addition to a working Haskell dev environment, you need to:
- build the `proto-lens-protoc` executable (`proto-lens`)
- build the `http2-client-grpc-exe` executable (this project)
- install the `protoc` executable

### Adding .proto files to a Haskell package

In order to run gRPC:

- generate the `Proto` stubs in some `gen` directory
- generate the `GRPC` stubs in some `gen` directory (you can re-use a same repository)

A single `protoc` invocation may be enough for both Proto and GRPC outputs:

```bash
protoc  "--plugin=protoc-gen-haskell-protolens=${protolens}" \
    "--plugin=protoc-gen-haskell-grpc=${grpc}" \
    --haskell-protolens_out=./gen \
    --haskell-grpc_out=./gen \
    -I "${protodir1} \
    -I "${protodir2} \
    ${first.proto} \
    ${second.proto}
```

- add the `gen` sourcedir for the generated to your .cabal/package.yaml file (cf. 'hs-source-dirs').
- add the generated Proto and GRPC modules to the 'exposed-modules' (or 'other-modules') keys

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

The Protobuf format specifies the notion of Service which can have one or more RPCs.
The gRPC protocal maps these services onto HTTP2 headers.

The library currently maps every `(Service, RPC)` to a `data Service_RPC` with
a single, argumentless, constructor `Service_RPC`. This naming convention
avoids name conflicts.

The input and output messages, as well as the HTTP2 `:path` pseudo-header are
encoded in a typeclass `Network.GRPC.RPC`. The generator will also instantiate
the typeclass for every `Service, RPC`. 

This machinery allows the `Network.GRPC.call` to be type safe and the only
entry-point you care about for making RPCs. You can then wrap this function
with whatever metrics/benchmark code and have all your RPC calls be monitored
in a uniform way.

## Status

This library is currently experimental.

## TODOs

- pass timeout as argument
- support compression
- provide function to map raw results into commonly-understood GRPC errors
