#!/usr/bin/env bash
# Configure Ubuntu/Linux host kernel, VM sysctls, CPU EPP, and linger for
# dedicated Strix Halo (gfx1151, 128 GB UMA) inference with strixite.
set -euo pipefail

IOMMU_MODE="off"       # off | pt | keep
GTT_MIB="131072"       # 128 GiB aperture
TTM_PAGES="32505856"   # 124 GiB TTM limit (32505856 * 4 KiB)
TARGET_USER="${SUDO_USER:-$USER}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --iommu off|pt|keep   Set AMD IOMMU kernel mode (default: off -> amd_iommu=off)
                        Use 'pt' if you need NPU (amdxdna) or VFIO passthrough.
  --gtt-mib N           amdgpu.gttsize in MiB (default: 131072)
  --ttm-pages N         ttm.pages_limit in 4K pages (default: 32505856 = 124 GiB)
  --user NAME           User for loginctl enable-linger (default: current user)
  --dry-run             Print actions without modifying the system
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iommu) IOMMU_MODE="${2:?missing value}"; shift 2 ;;
    --gtt-mib) GTT_MIB="${2:?missing value}"; shift 2 ;;
    --ttm-pages) TTM_PAGES="${2:?missing value}"; shift 2 ;;
    --user) TARGET_USER="${2:?missing value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "=== 1. Installing sysctl tuning (/etc/sysctl.d/99-strix-halo.conf) ==="
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] sudo install -m 0644 ${REPO_DIR}/configs/99-strix-halo.conf /etc/sysctl.d/99-strix-halo.conf"
  echo "[dry-run] sudo sysctl --system"
else
  sudo install -m 0644 "${REPO_DIR}/configs/99-strix-halo.conf" /etc/sysctl.d/99-strix-halo.conf
  sudo sysctl --system | grep -E "vm\.(swappiness|vfs_cache_pressure|dirty_)"
fi

echo "=== 2. Enabling AMD P-State EPP performance service ==="
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] sudo install -m 0644 ${REPO_DIR}/configs/cpu-epp-performance.service /etc/systemd/system/cpu-epp-performance.service"
  echo "[dry-run] sudo systemctl daemon-reload && sudo systemctl enable --now cpu-epp-performance.service"
else
  sudo install -m 0644 "${REPO_DIR}/configs/cpu-epp-performance.service" /etc/systemd/system/cpu-epp-performance.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now cpu-epp-performance.service
  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
    echo "CPU EPP values:"
    cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort | uniq -c
  fi
fi

echo "=== 3. Enabling systemd user linger for ${TARGET_USER} ==="
run sudo loginctl enable-linger "${TARGET_USER}"

echo "=== 4. Checking user device groups (render, video) ==="
if ! id -nG "${TARGET_USER}" | grep -qw render || ! id -nG "${TARGET_USER}" | grep -qw video; then
  echo "Adding ${TARGET_USER} to render and video groups (takes effect on next login/reboot)..."
  run sudo usermod -aG render,video "${TARGET_USER}"
else
  echo "${TARGET_USER} already in render and video."
fi

echo "=== 5. Updating kernel boot parameters ==="
GRUB_FILE="/etc/default/grub"
if [[ -f "${GRUB_FILE}" ]]; then
  CUR_CMDLINE="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUB_FILE}" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')"
  # Strip any prior occurrences of the parameters we manage
  NEW_TOKENS=()
  for tok in ${CUR_CMDLINE}; do
    case "${tok}" in
      amd_iommu=*|iommu=*|amdgpu.gttsize=*|ttm.pages_limit=*) ;;
      *) NEW_TOKENS+=("${tok}") ;;
    esac
  done
  case "${IOMMU_MODE}" in
    off) NEW_TOKENS+=("amd_iommu=off") ;;
    pt)  NEW_TOKENS+=("iommu=pt") ;;
    keep) ;;
    *) echo "Invalid --iommu value: ${IOMMU_MODE} (expected off|pt|keep)" >&2; exit 1 ;;
  esac
  NEW_TOKENS+=("amdgpu.gttsize=${GTT_MIB}" "ttm.pages_limit=${TTM_PAGES}")
  NEW_CMDLINE="${NEW_TOKENS[*]}"

  if [[ "${CUR_CMDLINE}" == "${NEW_CMDLINE}" ]]; then
    echo "GRUB_CMDLINE_LINUX_DEFAULT already matches: \"${NEW_CMDLINE}\""
  else
    BACKUP="${GRUB_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    echo "Updating ${GRUB_FILE} (backup: ${BACKUP})"
    echo "  old: \"${CUR_CMDLINE}\""
    echo "  new: \"${NEW_CMDLINE}\""
    if [[ "$DRY_RUN" -eq 0 ]]; then
      sudo cp "${GRUB_FILE}" "${BACKUP}"
      sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" "${GRUB_FILE}"
      if command -v update-grub >/dev/null 2>&1; then
        sudo update-grub
      elif command -v grub2-mkconfig >/dev/null 2>&1; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
      else
        echo "Warning: neither update-grub nor grub2-mkconfig found; regenerate your bootloader config manually." >&2
      fi
    fi
    echo "NOTE: Reboot required for kernel boot parameters to take effect."
  fi
else
  echo "Warning: ${GRUB_FILE} not found; configure amd_iommu=${IOMMU_MODE}, amdgpu.gttsize=${GTT_MIB}, ttm.pages_limit=${TTM_PAGES} via grubby/systemd-boot manually." >&2
fi
