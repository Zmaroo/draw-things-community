# grpc-swift-2 Phase 3 Checklist (Remove Legacy Bridge)

This checklist tracks the final migration from mixed runtime (grpc-swift v1 + grpc-swift-2) to pure grpc-swift-2.

## Current state

- `protoc-gen-grpc-swift-2` generated stubs are in use.
- Runtime still uses `import GRPC` APIs via `GRPCLegacyCompat` shims.
- `//Apps:gRPCServerCLI` builds and `//Libraries/GRPC:GRPCServerResponseEncodingTests` passes.

## Goal

- Remove `GRPCLegacyCompat` entirely.
- Remove grpc-swift v1 runtime dependency from production targets.
- Keep behavior and wire compatibility unchanged for existing clients.

## Tasks

1. `ImageGenerationClientWrapper` client migration
- Replace `ImageGenerationServiceNIOClient` calls with grpc-swift-2 client transport and generated `ImageGenerationService.Client` usage.
- Preserve existing call options and decompression behavior.

2. `ProxyControlClient` client migration
- Replace `ControlPanelServiceNIOClient` calls with grpc-swift-2 client APIs.
- Keep current request/response semantics and completion callbacks.

3. `ProxyGPUClientWrapper` client migration
- Replace legacy client calls with grpc-swift-2 client APIs.
- Keep echo/hours behavior unchanged.

4. `ImageGenerationServiceImpl` server migration
- Move from `ImageGenerationServiceProvider` to `ImageGenerationService.ServiceProtocol` (or `StreamingServiceProtocol`) implementation.
- Replace legacy call-context APIs with `ServerContext` and grpc-swift-2 response streams.
- Preserve chunking, payload types, terminal tags, cancellation behavior.

5. `ProxyCPUServer` server migration
- Move `ControlPanelService` and `ImageGenerationProxyService` to grpc-swift-2 service protocols.
- Preserve authentication, queueing, throttling, and heartbeat behavior.

6. Interceptor/middleware migration
- Replace legacy `*ServerInterceptorFactoryProtocol` usage with grpc-swift-2 middleware/interceptor model.
- Ensure request ID and tracing tags remain available.

7. Delete compatibility layer
- Remove `Libraries/GRPC/LegacyCompat/Sources/*`.
- Remove `GRPCLegacyCompat` target from `Libraries/GRPC/BUILD`.
- Remove `import GRPCLegacyCompat` in runtime sources.

8. Remove grpc-swift v1 runtime dependency
- Remove `@grpc-swift//:GRPC` from runtime targets once no legacy APIs remain.
- Keep v1 plugin only if still needed for any generation path; otherwise remove.

9. Validate
- `bazel build //Apps:gRPCServerCLI //Libraries/GRPC:all`
- `bazel test //Libraries/GRPC:GRPCServerResponseEncodingTests`
- Add/adjust tests for migrated server streaming paths.

## Exit criteria

- No runtime target imports `GRPC` v1-only APIs.
- No references remain to:
  - `ImageGenerationServiceNIOClient`
  - `ControlPanelServiceNIOClient`
  - `ImageGenerationServiceProvider`
  - `ControlPanelServiceProvider`
- `GRPCLegacyCompat` deleted.
- Build/test targets above are green.
