#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

storage=${1:-/var/lib/containerd}
bin_dir=${BIN_DIR:-/usr/bin}

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
      "$bin_dir/nerdctl"

rm -f /etc/crictl.yaml
rm -rf /opt/containerd
rm -f /etc/ld.so.conf.d/containerd.conf
command_exists ldconfig && ldconfig || true

log "containerd runtime cleaned"

