#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bin_dir=${BIN_DIR:-/usr/bin}

disable_and_stop kubelet.service

rm -f "$bin_dir/conntrack" \
      "$bin_dir/kubelet-pre-start.sh" \
      "$bin_dir/kubelet-post-stop.sh" \
      "$bin_dir/kubeadm" \
      "$bin_dir/kubectl" \
      "$bin_dir/kubelet"

sed -i '/ # sealos/d' /etc/sysctl.conf 2>/dev/null || true

sealos_b='### sealos begin ###'
sealos_e='### sealos end ###'
if [ -f /etc/security/limits.conf ] && grep -E "($sealos_b|$sealos_e)" /etc/security/limits.conf >/dev/null 2>&1; then
  slb=$(grep -nE "($sealos_b|$sealos_e)" /etc/security/limits.conf | head -n 1 | awk -F: '{print $1}')
  sle=$(grep -nE "($sealos_b|$sealos_e)" /etc/security/limits.conf | tail -n 1 | awk -F: '{print $1}')
  sed -i "${slb},${sle}d" /etc/security/limits.conf
fi

rm -f /etc/systemd/system/kubelet.service
rm -rf /etc/systemd/system/kubelet.service.d
rm -rf /var/lib/kubelet

log "kubelet cleaned"

