#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
kubectl -n cpu-lab create token chaos-lab-manager --duration=24h > "$SCRIPT_DIR/credentials/chaos-token.txt"
printf 'Updated %s/credentials/chaos-token.txt\n' "$SCRIPT_DIR"
