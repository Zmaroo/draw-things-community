# grpc-swift-2 Phase 3 Checklist (Remove Legacy Bridge)

This checklist tracked the final migration from mixed runtime (grpc-swift v1 + grpc-swift-2) to pure grpc-swift-2.

## Current state

- `protoc-gen-grpc-swift-2` generated stubs are in use.
- `GRPCLegacyCompat` shims are removed.
- `//Apps:gRPCServerCLI` builds and `//Libraries/GRPC:GRPCServerResponseEncodingTests` passes.

## Goal

- Remove `GRPCLegacyCompat` entirely.
- Remove grpc-swift v1 runtime dependency from production targets.
- Keep behavior and wire compatibility unchanged for existing clients.

## Tasks

1. `ImageGenerationClientWrapper` client migration (completed)
- Replaced `ImageGenerationServiceNIOClient` calls with grpc-swift-2 client transport and generated `ImageGenerationService.Client` usage.
- Preserved existing call options and decompression behavior.

2. `ProxyControlClient` client migration (completed)
- Replaced `ControlPanelServiceNIOClient` calls with grpc-swift-2 client APIs.
- Kept existing request/response semantics and completion callbacks.

3. `ProxyGPUClientWrapper` client migration (completed)
- Replaced legacy client calls with grpc-swift-2 client APIs.
- Kept echo/hours behavior unchanged.

4. `ImageGenerationServiceImpl` server migration (completed)
- Moved from `ImageGenerationServiceProvider` to grpc-swift-2 service protocols.
- Replaced legacy call-context APIs with grpc-swift-2 context/response stream APIs.
- Preserved chunking, payload types, terminal tags, and cancellation behavior.

5. `ProxyCPUServer` server migration (completed)
- Moved `ControlPanelService` and `ImageGenerationProxyService` to grpc-swift-2 service protocols.
- Preserved authentication, queueing, throttling, and heartbeat behavior.

6. Interceptor/middleware migration (completed)
- Replaced legacy `*ServerInterceptorFactoryProtocol` usage with grpc-swift-2 interceptor/middleware APIs.
- Kept request ID and tracing tag propagation.

7. Delete compatibility layer (completed)
- Removed `Libraries/GRPC/LegacyCompat/Sources/*`.
- Removed `GRPCLegacyCompat` target from `Libraries/GRPC/BUILD`.
- Removed runtime usage of `GRPCLegacyCompat`.

8. Remove grpc-swift v1 runtime dependency (completed)
- Removed `@grpc-swift//:GRPC` from runtime Bazel targets.
- Kept v1 plugin only where generation workflows still need it.

9. Validate (completed)
- `bazel build //Apps:gRPCServerCLI //Libraries/GRPC:all`
- `bazel test //Libraries/GRPC:GRPCServerResponseEncodingTests`
- Migration-path response-encoding coverage is green.

## Exit criteria

- No runtime target imports `GRPC` v1-only APIs.
- No references remain to:
  - `ImageGenerationServiceNIOClient`
  - `ControlPanelServiceNIOClient`
  - `ImageGenerationServiceProvider`
  - `ControlPanelServiceProvider`
- `GRPCLegacyCompat` deleted.
- Build/test targets above are green.
