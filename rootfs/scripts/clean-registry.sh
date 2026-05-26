#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

data=${1:-/var/lib/registry}
config=${2:-/etc/registry}
bin_dir=${BIN_DIR:-/usr/bin}

disable_and_stop registry.service

rm -f /etc/systemd/system/registry.service
rm -f "$bin_dir/registry"
rm -rf "$data" "$config"
rm -f /etc/registry.yml

log "registry cleaned"

