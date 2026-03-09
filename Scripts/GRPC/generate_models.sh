#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MODELS_DIR="${REPO_ROOT}/Libraries/GRPC/Models/Sources"

if ! command -v protoc >/dev/null 2>&1; then
  echo "error: protoc is not installed."
  echo "Install Protocol Buffers compiler first, then retry."
  exit 1
fi

if ! command -v protoc-gen-swift >/dev/null 2>&1; then
  echo "error: protoc-gen-swift is not installed."
  echo "Install swift-protobuf plugin first, then retry."
  exit 1
fi

PROTOC_GRPC_SWIFT_PLUGIN=""
if command -v protoc-gen-grpc-swift >/dev/null 2>&1; then
  PROTOC_GRPC_SWIFT_PLUGIN="$(command -v protoc-gen-grpc-swift)"
elif command -v protoc-gen-grpc-swift-2 >/dev/null 2>&1; then
  PROTOC_GRPC_SWIFT_PLUGIN="$(command -v protoc-gen-grpc-swift-2)"
else
  echo "error: protoc-gen-grpc-swift plugin is not installed."
  echo "Install grpc-swift plugin first, then retry."
  exit 1
fi

generate_proto() {
  local proto_name="$1"
  local proto_dir="${MODELS_DIR}/${proto_name}"
  local proto_file="${proto_dir}/${proto_name}.proto"

  if [[ ! -f "${proto_file}" ]]; then
    echo "error: missing proto file: ${proto_file}"
    exit 1
  fi

  protoc \
    --plugin=protoc-gen-grpc-swift="${PROTOC_GRPC_SWIFT_PLUGIN}" \
    --proto_path="${proto_dir}" \
    --swift_out=Visibility=Public:"${proto_dir}" \
    --grpc-swift_out=Visibility=Public:"${proto_dir}" \
    "${proto_file}"
}

generate_proto "imageService"
generate_proto "controlPanel"

echo "Regenerated gRPC model sources:"
echo "  - ${MODELS_DIR}/imageService/imageService.pb.swift"
echo "  - ${MODELS_DIR}/imageService/imageService.grpc.swift"
echo "  - ${MODELS_DIR}/controlPanel/controlPanel.pb.swift"
echo "  - ${MODELS_DIR}/controlPanel/controlPanel.grpc.swift"
