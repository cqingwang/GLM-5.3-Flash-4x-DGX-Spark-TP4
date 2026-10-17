#!/usr/bin/env bash
# Relay runtime checkpoints rank by rank while retaining cross-directory hardlinks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARK_DIR="$(cd "$MODULE_DIR/.." && pwd)"
cd "$MODULE_DIR"
ENV_FILE="${ENV_FILE:-.env.spark-ring}"
[[ -f $ENV_FILE ]] || { echo "missing managed environment: $ENV_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"

[[ ${TRANSPORT:-} == ring-only ]] || { echo 'model relay requires TRANSPORT=ring-only' >&2; exit 2; }
[[ ${REMOTE_USER:-} =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'REMOTE_USER is invalid' >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || { echo 'rsync is required' >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo 'ssh is required' >&2; exit 2; }

MODEL_ROOT="${MODEL_ROOT:-/opt/models}"
MODEL_PATHS=(
  nvidia/GLM-5.3-Flash-NVFP4
  glm-quant-mix/lossless8
  incoai/GLM-5.3-Flash-DFlash2
)
EXPECTED_CONFIGS=(
  e23c5d98f53e861d49a51bd3c68591621c5482ce829e42c31724152322fba03d
  f14dc13ce3bef88a5539c9e61b3e4f3dbef6958ebc3acda4b7f05f418642c3b0
  c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573
)
for index in "${!MODEL_PATHS[@]}"; do
  model_path="$MODEL_ROOT/${MODEL_PATHS[$index]}"
  config_path="$model_path/config.json"
  [[ -d $model_path && -f $config_path ]] || { echo "incomplete runtime model: $model_path" >&2; exit 2; }
  expected=${EXPECTED_CONFIGS[$index]}
  actual="$(sha256sum "$config_path" | awk '{print $1}')"
  [[ $actual == "$expected" ]] || { echo "unexpected config hash for $model_path: $actual" >&2; exit 2; }
done

ROUTE_FILE="$(mktemp -t glm53-ring-model-route.XXXXXX)"
trap 'rm -f "$ROUTE_FILE"' EXIT
python3 "$SPARK_DIR/program.py" ring-transfer-route --config "$SPARK_DIR/config.yaml" > "$ROUTE_FILE"
HEAD_NODE="$(awk -F '\t' 'NR == 1 { print $1 }' "$ROUTE_FILE")"
[[ $(hostname -s) == "$HEAD_NODE" ]] || { echo "run model relay on rank 0 ($HEAD_NODE)" >&2; exit 2; }

hop=0
while IFS=$'\t' read -r source_node source_management source_iface source_fabric target_node target_management target_fabric; do
  echo "Relaying model files $source_node -> $target_node over $source_iface ($source_fabric -> $target_fabric)"
  if [[ $hop == 0 ]]; then
    sources=()
    for model_path in "${MODEL_PATHS[@]}"; do sources+=("$MODEL_ROOT/./$model_path"); done
    rsync -aH --numeric-ids --partial --append-verify --info=progress2 --relative \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=15 -b $source_fabric" \
      "${sources[@]}" "$REMOTE_USER@$target_fabric:$MODEL_ROOT/"
  else
    remote_command="mkdir -p '$MODEL_ROOT' && rsync -aH --numeric-ids --partial --append-verify --info=progress2 --relative -e 'ssh -o BatchMode=yes -o ConnectTimeout=15 -b $source_fabric'"
    for model_path in "${MODEL_PATHS[@]}"; do remote_command+=" '$MODEL_ROOT/./$model_path'"; done
    remote_command+=" '$REMOTE_USER@$target_fabric:$MODEL_ROOT/'"
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE_USER@$source_management" "$remote_command"
  fi

  for index in "${!MODEL_PATHS[@]}"; do
    expected=${EXPECTED_CONFIGS[$index]}
    remote_config="$MODEL_ROOT/${MODEL_PATHS[$index]}/config.json"
    actual="$(ssh -n -o BatchMode=yes "$REMOTE_USER@$target_management" "sha256sum '$remote_config' | awk '{print \$1}'")"
    [[ $actual == "$expected" ]] || { echo "unexpected config hash on $target_node:$remote_config: $actual" >&2; exit 1; }
  done
  hop=$((hop + 1))
done < "$ROUTE_FILE"

[[ $hop == 3 ]] || { echo "expected three adjacent ring hops, completed $hop" >&2; exit 1; }
echo "All runtime model paths and pinned config hashes reached the four ranks"
