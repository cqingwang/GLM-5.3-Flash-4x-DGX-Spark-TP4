#!/usr/bin/env bash
# Export one ARM64 image on rank 0 and relay it over adjacent /30 ring links.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARK_DIR="$(cd "$MODULE_DIR/.." && pwd)"
cd "$MODULE_DIR"
ENV_FILE="${ENV_FILE:-.env.spark-ring}"
[[ -f $ENV_FILE ]] || { echo "missing managed environment: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"
read -r -a IPS <<<"$IPS"

[[ ${TRANSPORT:-} == ring-only ]] || { echo 'image relay requires TRANSPORT=ring-only' >&2; exit 2; }
[[ ${IMAGE:-} =~ ^[a-zA-Z0-9./:_-]+$ ]] || { echo 'IMAGE must be a simple Docker image reference' >&2; exit 2; }
[[ ${REMOTE_USER:-} =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'REMOTE_USER is invalid' >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || { echo 'rsync is required' >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo 'ssh is required' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'docker is required on rank 0' >&2; exit 2; }

ROUTE_FILE="$(mktemp -t glm53-ring-route.XXXXXX)"
trap 'rm -f "$ROUTE_FILE"' EXIT
python3 "$SPARK_DIR/program.py" ring-transfer-route --config "$SPARK_DIR/config.yaml" > "$ROUTE_FILE"
HEAD_NODE="$(awk -F '\t' 'NR == 1 { print $1 }' "$ROUTE_FILE")"
[[ $(hostname -s) == "$HEAD_NODE" ]] || { echo "run image relay on rank 0 ($HEAD_NODE)" >&2; exit 2; }

IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)" \
  || { echo "image is not built on rank 0: $IMAGE" >&2; exit 2; }
all_nodes_match=1
for rank in 1 2 3; do
  worker_ip="${IPS[$rank]}"
  worker_image_id="$(ssh -n -o BatchMode=yes "$REMOTE_USER@$worker_ip" "docker image inspect --format '{{.Id}}' '$IMAGE' 2>/dev/null || true")"
  [[ $worker_image_id == "$IMAGE_ID" ]] || all_nodes_match=0
done
if [[ $all_nodes_match == 1 ]]; then
  echo "Image $IMAGE with ID $IMAGE_ID is already present on all four ranks"
  exit 0
fi
SAFE_IMAGE="${IMAGE//\//_}"
SAFE_IMAGE="${SAFE_IMAGE//:/_}"
IMAGE_DIR="${IMAGE_ARCHIVE_DIR:-/opt/spark/images}"
mkdir -p "$IMAGE_DIR"
IMAGE_ARCHIVE="$IMAGE_DIR/${SAFE_IMAGE}.tar"
PARTIAL_ARCHIVE="$IMAGE_ARCHIVE.partial"
REMOTE_ARCHIVE="/var/tmp/${SAFE_IMAGE}-$$.tar"

echo "Exporting $IMAGE ($IMAGE_ID) on $HEAD_NODE"
docker save "$IMAGE" > "$PARTIAL_ARCHIVE"
mv "$PARTIAL_ARCHIVE" "$IMAGE_ARCHIVE"
sha256sum "$IMAGE_ARCHIVE" | tee "$IMAGE_ARCHIVE.sha256"

hop=0
while IFS=$'\t' read -r source_node source_management source_iface source_fabric target_node target_management target_fabric; do
  [[ -n $target_fabric ]] || { echo "incomplete route row: $source_node" >&2; exit 2; }
  echo "Relaying $source_node -> $target_node over $source_iface ($source_fabric -> $target_fabric)"
  if [[ $hop == 0 ]]; then
    rsync -aP --partial --append-verify \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=15 -b $source_fabric" \
      "$IMAGE_ARCHIVE" "$REMOTE_USER@$target_fabric:$REMOTE_ARCHIVE"
    ssh -o BatchMode=yes -o ConnectTimeout=15 -b "$source_fabric" "$REMOTE_USER@$target_fabric" \
      "docker load -i '$REMOTE_ARCHIVE' >/dev/null" </dev/null
  else
    remote_command="rsync -aP --partial --append-verify -e 'ssh -o BatchMode=yes -o ConnectTimeout=15 -b $source_fabric' '$REMOTE_ARCHIVE' '$REMOTE_USER@$target_fabric:$REMOTE_ARCHIVE' && ssh -o BatchMode=yes -o ConnectTimeout=15 -b '$source_fabric' '$REMOTE_USER@$target_fabric' 'docker load -i $REMOTE_ARCHIVE >/dev/null'"
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE_USER@$source_management" "$remote_command"
    ssh -n -o BatchMode=yes "$REMOTE_USER@$source_management" "rm -f '$REMOTE_ARCHIVE'"
  fi
  target_image_id="$(ssh -n -o BatchMode=yes "$REMOTE_USER@$target_management" "docker image inspect --format '{{.Id}}' '$IMAGE'")"
  [[ $target_image_id == "$IMAGE_ID" ]] || {
    echo "$target_node image ID mismatch: expected $IMAGE_ID, got $target_image_id" >&2
    exit 1
  }
  hop=$((hop + 1))
done < "$ROUTE_FILE"

last_target="$(awk -F '\t' 'END { print $5 }' "$ROUTE_FILE")"
last_management="$(awk -F '\t' 'END { print $6 }' "$ROUTE_FILE")"
ssh -n -o BatchMode=yes "$REMOTE_USER@$last_management" "rm -f '$REMOTE_ARCHIVE'"
[[ $hop == 3 ]] || { echo "expected three adjacent ring hops, completed $hop" >&2; exit 1; }
echo "Image $IMAGE with ID $IMAGE_ID is present on all four ranks; source archive: $IMAGE_ARCHIVE"
