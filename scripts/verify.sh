#!/usr/bin/env bash
# Verify Strix Halo kernel parameters, GPU GTT memory, sysctls, CPU EPP,
# Quadlet service, and live strixite endpoint health.
set -euo pipefail

PORT="${PORT:-5300}"
HOST="${HOST:-127.0.0.1}"

echo "=== 1. Kernel Boot Parameters & IOMMU ==="
cat /proc/cmdline
IOMMU_GROUPS="$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l || true)"
echo "IOMMU groups count: ${IOMMU_GROUPS} (0 = amd_iommu=off active)"

echo "=== 2. GPU Memory (VRAM Carveout & GTT) ==="
for card in /sys/class/drm/card*; do
  [[ -r "${card}/device/mem_info_gtt_total" ]] || continue
  vram_total=$(cat "${card}/device/mem_info_vram_total")
  gtt_total=$(cat "${card}/device/mem_info_gtt_total")
  gtt_used=$(cat "${card}/device/mem_info_gtt_used")
  awk -v vt="$vram_total" -v gt="$gtt_total" -v gu="$gtt_used" -v c="$card" \
    'BEGIN { printf "%s: VRAM=%.2f GiB, GTT_total=%.2f GiB, GTT_used=%.2f GiB\n", c, vt/1073741824, gt/1073741824, gu/1073741824 }'
done

echo "=== 3. VM Sysctls & CPU EPP ==="
sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_bytes vm.dirty_bytes
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
  echo "CPU EPP distribution:"
  cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort | uniq -c
fi
free -h

echo "=== 4. Systemd Service & Direct Socket Bind ==="
systemctl --user is-active strixite.service
ss -tlnp 2>/dev/null | grep ":${PORT} " || true

echo "=== 5. API & Metrics Check (http://${HOST}:${PORT}) ==="
curl -fsS "http://${HOST}:${PORT}/v1/models"
echo ""
curl -fsS "http://${HOST}:${PORT}/metrics" | grep -E "^strix_(requests_total|context_length|mtp_acceptance_rate|prompt_cache_(ram_bytes|bytes|room_refused_total))" || true
