#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

data=${1:-/var/lib/registry}
config=${2:-/etc/registry}
bin_dir=${BIN_DIR:-/usr/bin}

mkdir -p "$data" "$config"

install_file ../etc/registry.service /etc/systemd/system/registry.service
install_binary ../cri/registry "$bin_dir/registry"
install_file ../etc/registry_config.yml "$config/registry_config.yml"
install_file ../etc/registry_htpasswd "$config/registry_htpasswd" 0600

ensure_selinux_permissive
enable_and_restart registry.service
check_status registry.service
log "registry initialized"

