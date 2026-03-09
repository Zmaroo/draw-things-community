# grpc-swift-2 Migration Notes

This repository currently uses grpc-swift v1 runtime (`import GRPC`) in server/client code.

`protoc-gen-grpc-swift-2` generates stubs that use:

- `import GRPCCore`
- `import GRPCProtobuf`

and service APIs based on async `ServerContext` / `StreamingServerRequest` / `StreamingServerResponse`.

## What this migration requires

1. Add Bazel external deps for:
   - `grpc-swift-2` (`GRPCCore`, `GRPCCodeGen`, `GRPCInProcessTransport`)
   - `grpc-swift-protobuf` (`GRPCProtobuf`, `protoc-gen-grpc-swift-2`)
2. Regenerate model stubs with `Scripts/GRPC/generate_models_v2.sh`.
3. Replace runtime usage in handwritten code:
   - `ImageGenerationServiceImpl.swift`
   - `ImageGenerationClientWrapper.swift`
   - `ProxyCPUServer.swift`
   - `ProxyControlClient.swift`
   - `GRPCFileUploader.swift`
   - any call-context/provider/interceptor types imported from `GRPC`.
4. Update Bazel target deps from `@grpc-swift//:GRPC` to `@grpc-swift-2//:GRPCCore` and `@grpc-swift-protobuf//:GRPCProtobuf` as needed.
5. Rework tests to new APIs and restore green status.

## Platform baseline

The new grpc-swift-2 stack uses availability macros mapped to:

- macOS 15.0
- iOS 18.0
- watchOS 11.0
- tvOS 18.0
- visionOS 2.0

If older deployment targets are required, this migration cannot be completed as-is.

## Current transitional state

The repository currently uses a temporary bridge module:

- `Libraries/GRPC/LegacyCompat`

This is an intentional transitional layer to keep existing runtime behavior while
moving generated models and Bazel externals to grpc-swift-2.

For bridge removal and full runtime migration, follow:

- `Libraries/GRPC/Models/GRPC_SWIFT_2_PHASE3_CHECKLIST.md`
