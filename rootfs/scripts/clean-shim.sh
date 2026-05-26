#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bin_dir=${BIN_DIR:-/usr/bin}

disable_and_stop image-cri-shim.service
rm -f /etc/systemd/system/image-cri-shim.service
rm -f "$bin_dir/image-cri-shim"
rm -f /etc/image-cri-shim.yaml
rm -rf /var/lib/image-cri-shim

log "image-cri-shim cleaned"

