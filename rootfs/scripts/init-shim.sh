#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bin_dir=${BIN_DIR:-/usr/bin}

install_file ../etc/image-cri-shim.service /etc/systemd/system/image-cri-shim.service
install_file ../etc/image-cri-shim.yaml /etc/image-cri-shim.yaml
install_binary ../cri/image-cri-shim "$bin_dir/image-cri-shim"
[ -f ../etc/crictl.yaml ] && install_file ../etc/crictl.yaml /etc/crictl.yaml

enable_and_restart image-cri-shim.service
check_status image-cri-shim.service
log "image-cri-shim initialized"

