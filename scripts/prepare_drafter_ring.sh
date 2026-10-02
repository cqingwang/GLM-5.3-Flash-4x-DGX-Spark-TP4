#!/usr/bin/env bash
# Re-encode the licensed drafter independently on each host; never relay its derivative.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MODULE_DIR"
ENV_FILE="${ENV_FILE:-.env.spark-ring}"
[[ -f $ENV_FILE ]] || { echo "missing managed environment: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"
read -r -a HOSTS <<<"$HOSTS"
read -r -a IPS <<<"$IPS"

[[ ${TRANSPORT:-} == ring-only ]] || { echo 'drafter preparation requires the managed ring target' >&2; exit 2; }
[[ ${REMOTE_USER:-} =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'REMOTE_USER is invalid' >&2; exit 2; }
[[ ${IMAGE:-} =~ ^[a-zA-Z0-9./:_-]+$ ]] || { echo 'IMAGE must be a simple Docker image reference' >&2; exit 2; }
[[ ${#HOSTS[@]} == 4 && ${#IPS[@]} == 4 ]] || { echo 'drafter preparation requires all four ranks' >&2; exit 2; }

MODEL_ROOT="${MODEL_ROOT:-/opt/models}"
SOURCE="$MODEL_ROOT/incoai/GLM-5.3-Flash-DFlash2"
DESTINATION="$MODEL_ROOT/incoai/GLM-5.3-Flash-DFlash2-fp8blk"
EXPECTED_SHA256=15bc842939ff7ca3ccc5aad36d25fff854da05a60086a4f55672d804fc6dbe7b
CONTAINER_SUFFIX="$(date +%Y%m%d%H%M%S)"
USER_ID="$(id -u):$(id -g)"

prepare_local() {
  [[ -d $SOURCE ]] || { echo "missing original drafter: $SOURCE" >&2; return 2; }
  if [[ -d $DESTINATION ]]; then
    actual="$(sha256sum "$DESTINATION/config.json" 2>/dev/null | awk '{print $1}')"
    [[ $actual == "$EXPECTED_SHA256" ]] || { echo "refusing to overwrite an existing drafter derivative at $DESTINATION" >&2; return 2; }
    echo "drafter derivative already verified on $(hostname -s)"
    return 0
  fi
  container="glm53-drafter-fp8blk-r${rank}-${CONTAINER_SUFFIX}"
  docker run --name "$container" --network none --memory 16g --cpus 4 \
    --user "$USER_ID" -e HOME=/tmp \
    -v "$MODULE_DIR:/recipe:ro" -v "$MODEL_ROOT:/models" \
    --entrypoint bash "$IMAGE" -c \
    'set -e; python3 /recipe/scripts/drafter_fp8.py /models/incoai/GLM-5.3-Flash-DFlash2 /models/incoai/GLM-5.3-Flash-DFlash2-fp8blk'
  actual="$(sha256sum "$DESTINATION/config.json" | awk '{print $1}')"
  [[ $actual == "$EXPECTED_SHA256" ]] || { echo "generated drafter config hash mismatch on $(hostname -s): $actual" >&2; return 1; }
  echo "prepared drafter derivative on $(hostname -s) in preserved container $container"
}

for rank in 0 1 2 3; do
  if [[ $rank == 0 ]]; then
    prepare_local
    continue
  fi
  management_ip="${IPS[$rank]}"
  printf -v remote_command 'MODEL_ROOT=%q IMAGE=%q MODULE_DIR=%q USER_ID=%q EXPECTED_SHA256=%q bash -s -- %q %q' \
    "$MODEL_ROOT" "$IMAGE" "$MODULE_DIR" "$USER_ID" "$EXPECTED_SHA256" "$rank" "$CONTAINER_SUFFIX"
  ssh -o BatchMode=yes "$REMOTE_USER@$management_ip" "$remote_command" <<'REMOTE_DRAFTER'
set -euo pipefail
rank=$1
suffix=$2
source="$MODEL_ROOT/incoai/GLM-5.3-Flash-DFlash2"
destination="$MODEL_ROOT/incoai/GLM-5.3-Flash-DFlash2-fp8blk"
if [[ -d $destination ]]; then
  actual="$(sha256sum "$destination/config.json" 2>/dev/null | awk '{print $1}')"
  [[ $actual == "$EXPECTED_SHA256" ]] || { echo "refusing to overwrite an existing drafter derivative on $(hostname -s)" >&2; exit 2; }
  echo "drafter derivative already verified on $(hostname -s)"
  exit 0
fi
container="glm53-drafter-fp8blk-r${rank}-${suffix}"
docker run --name "$container" --network none --memory 16g --cpus 4 \
  --user "$USER_ID" -e HOME=/tmp \
  -v "$MODULE_DIR:/recipe:ro" -v "$MODEL_ROOT:/models" \
  --entrypoint bash "$IMAGE" -c \
  'set -e; python3 /recipe/scripts/drafter_fp8.py /models/incoai/GLM-5.3-Flash-DFlash2 /models/incoai/GLM-5.3-Flash-DFlash2-fp8blk'
actual="$(sha256sum "$destination/config.json" | awk '{print $1}')"
[[ $actual == "$EXPECTED_SHA256" ]] || { echo "generated drafter config hash mismatch on $(hostname -s): $actual" >&2; exit 1; }
echo "prepared drafter derivative on $(hostname -s) in preserved container $container"
REMOTE_DRAFTER
done
