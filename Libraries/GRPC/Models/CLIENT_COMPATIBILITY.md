# gRPC Client Compatibility Notes

This note documents response-format compatibility for external Draw Things gRPC clients.

## Request format fields

Preferred fields:

- `previewResponseFormat`
- `finalResponseFormat`
- `previewEveryNSteps`

Legacy field (still supported):

- `responseFormat`

Fallback order used by server:

1. If split fields are set, they take precedence.
2. Otherwise, server uses legacy `responseFormat`.
3. If nothing is set, server defaults to tensor payloads.

## Response payload semantics

- `previewImage` is a single payload per preview update.
- `generatedImages` may be chunked; use `chunkState` to reassemble.
- Use `previewPayloadType` / `finalPayloadType` to decode bytes when present.
- Keep PNG/JPEG fallback decoding for mixed-version clients.

## Regenerating Swift models from proto

Use the repo helper:

```bash
./Scripts/GRPC/generate_models.sh
```

This regenerates:

- `imageService.pb.swift`
- `imageService.grpc.swift`
- `controlPanel.pb.swift`
- `controlPanel.grpc.swift`
