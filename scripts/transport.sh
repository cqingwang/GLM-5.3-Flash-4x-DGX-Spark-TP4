# Transport-only opt-in. Source after the operator's environment/profile.
# Model, scheduler, precision and graph options are left to profiles/current.env.
configure_transport() {
  case ${TRANSPORT:-switched} in
    switched) return 0;;
    switchless) ;;
    ring-only) ;;
    *) echo 'TRANSPORT must be switched, switchless or ring-only' >&2; return 2;;
  esac
  if [[ ${TRANSPORT:-switched} == ring-only ]]; then
    [[ ${#HOSTS[@]} == 4 && ${#IPS[@]} == 4 ]] || { echo 'ring-only requires four hosts and four bootstrap IPs in common.ring rank order' >&2; return 2; }
    [[ ${NCCL_HOST_DIR:-} =~ ^/[a-zA-Z0-9_./-]+$ && $NCCL_HOST_DIR != / ]] || { echo 'absolute NCCL_HOST_DIR without whitespace required' >&2; return 2; }
    [[ ${NCCL_LIBRARY_SHA256:-} =~ ^[a-f0-9]{64}$ ]] || { echo 'NCCL_LIBRARY_SHA256 must pin the validated ring library' >&2; return 2; }
    [[ ${FABRIC_IFACE:-} =~ ^[a-zA-Z0-9_.:-]+$ && ${IB_HCA:-} =~ ^[a-zA-Z0-9_:.,-]+$ ]] || { echo 'management bootstrap interface and RDMA HCA list required' >&2; return 2; }
    [[ ${NCCL_IB_GID_INDEX:-} == -1 && ${NCCL_IB_SUBNET_PREFIX_LEN:-} == 30 ]] || { echo 'site ring requires automatic GID selection and the actual /30 link prefix' >&2; return 2; }
    local rank peer_name peer_value
    for rank in 0 1 2 3; do
      peer_name="PEER_HCA_RANK$rank"
      peer_value="${!peer_name:-}"
      [[ $peer_value =~ ^[0-3]=[a-zA-Z0-9_:.,-]+\;[0-3]=[a-zA-Z0-9_:.,-]+$ ]] || { echo "$peer_name must pin both physical ring neighbors" >&2; return 2; }
    done
    local kv clean=""
    for kv in ${EXTRA_ENV:-}; do
      case ${kv%%=*} in
        GLM_ROCE_ALLREDUCE|B12X_ROCE_HCA) ;;
        NCCL_*|LD_PRELOAD|VLLM_NCCL_SO_PATH|TORCH_USE_RTLD_GLOBAL|GLOO_SOCKET_IFNAME|MN_IF_NAME|TP_SOCKET_IFNAME|VLLM_HOST_IP)
          echo 'transport overrides in EXTRA_ENV conflict with ring-only configuration' >&2; return 2;;
        *) clean="$clean $kv";;
      esac
    done
    EXTRA_ENV="${clean# } GLM_ROCE_ALLREDUCE=0"
    return 0
  fi
  # All validation precedes the first remote action. Values enter a remote shell
  # command, so reject whitespace, metacharacters and ambiguous path expansions.
  [[ ${#HOSTS[@]} == 4 && ${#IPS[@]} == 4 ]] || { echo 'switchless requires four hosts and four bootstrap IPs in ring rank order' >&2; return 2; }
  [[ ${NCCL_HOST_DIR:-} =~ ^/[a-zA-Z0-9_./-]+$ && $NCCL_HOST_DIR != / ]] || { echo 'absolute NCCL_HOST_DIR without whitespace required' >&2; return 2; }
  [[ ${SWITCHLESS_NCCL_SHA256:-} =~ ^[a-f0-9]{64}$ ]] || { echo 'SWITCHLESS_NCCL_SHA256 must pin the patched library' >&2; return 2; }
  [[ ${FABRIC_IFACE:-} =~ ^[a-zA-Z0-9_.:-]+$ && ${IB_HCA:-} =~ ^[a-zA-Z0-9_:.,-]+$ ]] || { echo 'explicit bootstrap interface and HCA allowlist required' >&2; return 2; }
  [[ ${NCCL_IB_GID_INDEX:-3} =~ ^[0-9]+$ && ${SWITCHLESS_SUBNET_PREFIX_LEN:-24} =~ ^[0-9]+$ ]] || { echo 'numeric GID index and subnet prefix required' >&2; return 2; }
  # Validate IPv4 addressing without touching the network or reading environment.
  python3 - "${SWITCHLESS_ADDR_RANGE:-}" "${SWITCHLESS_SUBNET_PREFIX_LEN:-24}" "${IPS[@]}" <<'PY'
import ipaddress, sys
try:
    network = ipaddress.IPv4Network(sys.argv[1], strict=True)
    prefix = int(sys.argv[2])
    addresses = [ipaddress.IPv4Address(x) for x in sys.argv[3:]]
    assert network.prefixlen <= prefix <= 32 and len(set(addresses)) == 4
except (ValueError, AssertionError):
    raise SystemExit('valid switchless IPv4 range/subnet prefix and four distinct bootstrap IPs required')
PY
  local kv clean=""
  for kv in ${EXTRA_ENV:-}; do
    case ${kv%%=*} in
      GLM_ROCE_ALLREDUCE|B12X_ROCE_HCA) ;; # disabled for a ring, even if profile enables them
      NCCL_*|LD_PRELOAD|VLLM_NCCL_SO_PATH|TORCH_USE_RTLD_GLOBAL|GLOO_SOCKET_IFNAME|MN_IF_NAME|TP_SOCKET_IFNAME|VLLM_HOST_IP)
        echo 'transport overrides in EXTRA_ENV conflict with switchless configuration' >&2; return 2;;
      *) clean="$clean $kv";;
    esac
  done
  EXTRA_ENV="${clean# } GLM_ROCE_ALLREDUCE=0"
}

transport_args() {
  if [[ ${TRANSPORT:-switched} == ring-only ]]; then
    local rank=${1:-} peer_name peer_value
    [[ $rank =~ ^[0-3]$ ]] || { echo 'ring-only transport requires rank 0..3' >&2; return 2; }
    peer_name="PEER_HCA_RANK$rank"
    peer_value="${!peer_name:-}"
    printf '%s' "-e NCCL_SWITCHLESS_RING_ONLY=1 -e NCCL_ALGO=Ring \
-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA=$IB_HCA -e NCCL_IB_PEER_HCA='$peer_value' \
-e NCCL_IB_GID_INDEX=-1 -e NCCL_IB_GID_INDEX_FORCE=-1 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
-e NCCL_IB_SUBNET_PREFIX_LEN=30 -e NCCL_CROSS_NIC=1 -e NCCL_IB_MERGE_NICS=0 \
-e NCCL_NET_PLUGIN=none -e NCCL_SOCKET_IFNAME==$FABRIC_IFACE -e GLOO_SOCKET_IFNAME=$FABRIC_IFACE \
-e NCCL_P2P_DISABLE=1 -e NCCL_SHM_DISABLE=1 -e NCCL_IGNORE_CPU_AFFINITY=1 \
-e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 -e NCCL_BUFFSIZE=8388608 \
-e NCCL_IB_TIMEOUT=1000 -e NCCL_IB_RETRY_CNT=7 -e NCCL_IB_TOS=46 \
-e NCCL_CUMEM_ENABLE=0 -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,ENV"
    return
  fi
  if [[ ${TRANSPORT:-switched} != switchless ]]; then
    # Preserve the original switched command exactly, including interface match.
    # The continuation lines keep start.sh's original four-space indent, so the rendered command is byte-identical.
    printf '%s' "-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_NET_PLUGIN=none -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_IB_GID_INDEX=${NCCL_IB_GID_INDEX:-3} \
    -e NCCL_SOCKET_IFNAME==$FABRIC_IFACE -e GLOO_SOCKET_IFNAME=$FABRIC_IFACE -e NCCL_IB_HCA==$IB_HCA \
    -e NCCL_IB_MERGE_NICS=0 -e NCCL_CROSS_NIC=0 -e NCCL_NVLS_ENABLE=0 -e NCCL_CUMEM_ENABLE=0 -e NCCL_DEBUG=WARN"
    return
  fi
  printf '%s' "-e TORCH_USE_RTLD_GLOBAL=1 -e NCCL_SWITCHLESS_RING_ONLY=1 -e NCCL_ALGO=Ring \
-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA==$IB_HCA -e NCCL_IB_ADDR_FAMILY=AF_INET \
-e NCCL_IB_ADDR_RANGE=$SWITCHLESS_ADDR_RANGE -e NCCL_IB_ROCE_VERSION_NUM=2 \
-e NCCL_IB_SUBNET_AWARE_ROUTING=1 -e NCCL_IB_SUBNET_PREFIX_LEN=${SWITCHLESS_SUBNET_PREFIX_LEN:-24} \
-e NCCL_IB_MERGE_NICS=0 -e NCCL_CROSS_NIC=1 -e NCCL_SOCKET_IFNAME=$FABRIC_IFACE \
-e GLOO_SOCKET_IFNAME=$FABRIC_IFACE -e MN_IF_NAME=$FABRIC_IFACE -e TP_SOCKET_IFNAME=$FABRIC_IFACE \
-e NCCL_CUMEM_ENABLE=0 -e NCCL_DEBUG=INFO -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_MAX_CTAS=4 \
-e NCCL_NVLS_ENABLE=0 -e NCCL_IB_EXTENDED_IPV4_GIDS=1 -e NCCL_IB_PRESERVE_PCI_DOMAIN=1 -e NCCL_IB_ROUTE_DIAGNOSTICS=1 -e NCCL_DEBUG_SUBSYS=INIT,NET"
}
