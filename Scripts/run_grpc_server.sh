#!/usr/bin/env bash
set -euo pipefail

MIGRATION_REPO="/Users/Michaelmarler/draw-things-community"
MODELS_DIR_DEFAULT="/Users/michaelmarler/Library/Containers/com.liuliu.draw-things/Data/Documents/Models"

MODELS_DIR="${1:-${MODELS_DIR_DEFAULT}}"

exec /usr/bin/env bash -c "cd \"${MIGRATION_REPO}\" && \
  bazel run //Apps:gRPCServerCLI -- \\
    \"${MODELS_DIR}\" \\
    --address 127.0.0.1 \\
    --port 7859 \\
    --debug \\
    --no-tls \\
    --no-response-compression \\
    --model-browser \\
    --weights-cache 16"
