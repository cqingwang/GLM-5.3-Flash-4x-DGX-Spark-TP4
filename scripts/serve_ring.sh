#!/usr/bin/env bash
# The managed Spark target always seeds model files and its built image before TP4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-serve}"
shift || true
if [[ $ACTION == serve ]]; then
  "$SCRIPT_DIR/ship_models_ring.sh"
  "$SCRIPT_DIR/ship_image_ring.sh"
  "$SCRIPT_DIR/prepare_drafter_ring.sh"
  exec "$SCRIPT_DIR/../start.sh" serve "$@"
fi
exec "$SCRIPT_DIR/../start.sh" "$ACTION" "$@"
