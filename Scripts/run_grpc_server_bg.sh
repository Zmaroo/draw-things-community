#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/draw_things_grpc.log"

"${SCRIPT_DIR}/run_grpc_server.sh" > "${LOG_FILE}" 2>&1 &
echo "gRPC server started. Logs: ${LOG_FILE}"
