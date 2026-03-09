#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

./Scripts/GRPC/generate_models.sh

FILES=(
  "Libraries/GRPC/Models/Sources/imageService/imageService.pb.swift"
  "Libraries/GRPC/Models/Sources/imageService/imageService.grpc.swift"
  "Libraries/GRPC/Models/Sources/controlPanel/controlPanel.pb.swift"
  "Libraries/GRPC/Models/Sources/controlPanel/controlPanel.grpc.swift"
)

if ! git diff --quiet -- "${FILES[@]}"; then
  echo "error: generated gRPC model sources are out of date."
  echo "Run ./Scripts/GRPC/generate_models.sh and commit regenerated files."
  git diff -- "${FILES[@]}"
  exit 1
fi

echo "gRPC model sources are up to date."
