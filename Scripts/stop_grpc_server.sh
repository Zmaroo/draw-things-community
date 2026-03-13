#!/usr/bin/env bash
set -euo pipefail

PIDS=$(pgrep -f "gRPCServerCLI --address 127.0.0.1 --port 7859" || true)
if [[ -z "${PIDS}" ]]; then
  echo "No gRPCServerCLI process found on 127.0.0.1:7859"
  exit 0
fi

echo "Stopping gRPCServerCLI: ${PIDS}"
kill ${PIDS}
