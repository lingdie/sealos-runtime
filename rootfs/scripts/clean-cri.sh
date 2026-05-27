#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

storage=${1:-/var/lib/containerd}
bin_dir=${BIN_DIR:-/usr/bin}
local_bin_dir=${LOCAL_BIN_DIR:-/usr/local/bin}

disable_and_stop containerd.service

rm -rf /etc/containerd
rm -f /etc/systemd/system/containerd.service
rm -rf "$storage"
rm -rf /run/containerd
rm -rf /var/lib/nerdctl

rm -f "$bin_dir/containerd" \
      "$bin_dir/containerd-stress" \
      "$bin_dir/containerd-shim" \
      "$bin_dir/containerd-shim-runc-v1" \
      "$bin_dir/containerd-shim-runc-v2" \
      "$bin_dir/containerd-shim-runc-v2" \
      "$bin_dir/ctr" \
      "$bin_dir/ctd-decoder" \
      "$bin_dir/runc" \
      "$bin_dir/crictl" \
      "$bin_dir/crictl.real" \
      "$bin_dir/nerdctl"

if [ -f "$local_bin_dir/crictl" ] && grep -q 'sealos-runtime crictl wrapper' "$local_bin_dir/crictl" 2>/dev/null; then
  rm -f "$local_bin_dir/crictl"
fi
if [ -e "$local_bin_dir/crictl.sealos-backup" ]; then
  mv "$local_bin_dir/crictl.sealos-backup" "$local_bin_dir/crictl"
fi

rm -f /etc/crictl.yaml
rm -rf /opt/containerd
rm -f /etc/ld.so.conf.d/containerd.conf
command_exists ldconfig && ldconfig || true

log "containerd runtime cleaned"
