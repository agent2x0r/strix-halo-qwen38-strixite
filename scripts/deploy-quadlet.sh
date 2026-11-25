#!/usr/bin/env bash
# Deploy strixite as a rootless Podman Quadlet systemd user service using
# --network=host and tuned prompt-cache margins.
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-/mnt/models/strix-infer}"
STRIXITE_IMAGE="${STRIXITE_IMAGE:-ghcr.io/shawnshekari/strixite:v0.7.1}"
RAM_MARGIN_GIB="${RAM_MARGIN_GIB:-5}"
DISK_FREE_GIB="${DISK_FREE_GIB:-16}"
DISK_CACHE_GIB="${DISK_CACHE_GIB:-72}"
QUADLET_DIR="${HOME}/.config/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/strixite.container"

usage() {
  cat <<EOF
Usage: $0 [options]

Environment / Options:
  --models-dir PATH       Host model directory (default: ${MODELS_DIR})
  --image IMAGE           Container image (default: ${STRIXITE_IMAGE})
  --ram-margin-gib N      --prompt-cache-ram-margin-gib (default: ${RAM_MARGIN_GIB})
  --disk-free-gib N       --prompt-cache-disk-free-gib (default: ${DISK_FREE_GIB})
  --disk-cache-gib N      --prompt-cache-gib (default: ${DISK_CACHE_GIB})
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models-dir) MODELS_DIR="${2:?missing value}"; shift 2 ;;
    --image) STRIXITE_IMAGE="${2:?missing value}"; shift 2 ;;
    --ram-margin-gib) RAM_MARGIN_GIB="${2:?missing value}"; shift 2 ;;
    --disk-free-gib) DISK_FREE_GIB="${2:?missing value}"; shift 2 ;;
    --disk-cache-gib) DISK_CACHE_GIB="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

echo "=== Checking prerequisites ==="
command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }
[[ -e /dev/kfd ]] || { echo "/dev/kfd missing (is amdgpu/ROCm loaded?)" >&2; exit 1; }
[[ -d /dev/dri ]] || { echo "/dev/dri missing" >&2; exit 1; }
[[ -d "${MODELS_DIR}/converted" ]] || {
  echo "Expected converted weights under ${MODELS_DIR}/converted." >&2
  echo "Download with: hf download wemoh/Qwen3.8-Flash-Next-strixw --local-dir ${MODELS_DIR}" >&2
  exit 1
}

mkdir -p "${QUADLET_DIR}"
cat > "${QUADLET_FILE}" <<EOF
[Unit]
Description=Strixite Qwen3.8-Flash-Next inference server
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=strixite
Image=${STRIXITE_IMAGE}
Network=host
AddDevice=/dev/kfd
AddDevice=/dev/dri
GroupAdd=keep-groups
SecurityLabelDisable=true
SeccompProfile=unconfined
Volume=${MODELS_DIR}:/models
Exec=--prompt-cache-ram-margin-gib ${RAM_MARGIN_GIB} --prompt-cache-disk-free-gib ${DISK_FREE_GIB} --prompt-cache-gib ${DISK_CACHE_GIB}

[Service]
Restart=on-failure
RestartSec=5
TimeoutStopSec=90

[Install]
WantedBy=default.target
EOF

echo "Wrote ${QUADLET_FILE}"

if [[ -x /usr/libexec/podman/quadlet ]]; then
  echo "=== Validating Quadlet syntax ==="
  /usr/libexec/podman/quadlet -user -dryrun >/dev/null
fi

# Stop any manually created container with the same name before handing off to systemd
if podman container exists strixite 2>/dev/null; then
  echo "Stopping existing manual strixite container..."
  podman stop -t 90 strixite >/dev/null || true
  podman rm strixite >/dev/null || true
fi

echo "=== Pulling image (if needed) & starting strixite.service ==="
podman pull "${STRIXITE_IMAGE}"
systemctl --user daemon-reload
systemctl --user restart strixite.service
systemctl --user status strixite.service --no-pager -l | head -n 20

echo ""
echo "strixite.service is starting (~32-45 s to load 65.9 GiB weights)."
echo "Follow logs with: journalctl --user -u strixite.service -f"
