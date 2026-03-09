# gRPC Client Compatibility Notes

This note documents response-format compatibility for external Draw Things gRPC clients.

## Quick compatibility matrix

| Client behavior | Supported | Notes |
| --- | --- | --- |
| Legacy `responseFormat` only | Yes | Backward compatible path. |
| Split `previewResponseFormat` + `finalResponseFormat` | Yes | Preferred on newer clients. |
| `previewEveryNSteps` cadence control | Yes | Applies to sampling signposts. |
| `previewPayloadType` / `finalPayloadType` decode-first | Yes | Recommended on mixed deployments. |
| Chunked final payload reassembly (`chunkState`) | Yes | Required for large payloads. |

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
- Every stream update now includes structured `tags` entries:
  - `request_id=...`
  - `event_type=...`
  - optional `payload_type=...`, `chunk_index=...`, `chunk_total=...`
  - `is_terminal=true|false`
- Server emits a terminal stream event exactly once per request with:
  - `event_type=terminal`
  - `is_terminal=true`
  - `terminal_status=completed|cancelled|failed`

## Recommended format profile

- Preview: JPEG (`previewResponseFormat = RESPONSE_FORMAT_JPEG`) for lower bandwidth.
- Final: PNG (`finalResponseFormat = RESPONSE_FORMAT_PNG`) for quality-preserving output.
- Keep payload-type-first decoding and PNG/JPEG fallback enabled.

## Capability signal via Echo

`EchoReply.message` includes a line prefixed with:

- `CAPABILITIES key=value;key=value;...`

Current keys include:

- `protocol_version`
- `legacy_response_format`
- `split_response_formats`
- `payload_type_fields`
- `chunked_generated_images`
- `preview_single_payload`
- `default_response`
- `model_browsing`

## Regenerating Swift models from proto

Use the repo helper:

```bash
./Scripts/GRPC/generate_models.sh
```

Optional verification helper:

```bash
./Scripts/GRPC/verify_models_up_to_date.sh
```

This regenerates:

- `imageService.pb.swift`
- `imageService.grpc.swift`
- `controlPanel.pb.swift`
- `controlPanel.grpc.swift`
