#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

registry_data=${1:-/var/lib/registry}

[ "$(id -u)" -eq 0 ] || error "runtime scripts must run as root"

check_port_inuse

if command_exists docker; then
  error "docker is already installed; remove docker before installing this containerd runtime"
fi

if [ -S /var/run/docker.sock ]; then
  error "/var/run/docker.sock exists; remove docker before installing this containerd runtime"
fi

if [ -e "$registry_data" ]; then
  error "$registry_data already exists; clean the old registry data first"
fi

if ! command_exists apparmor_parser; then
  if [ -f ../etc/config.toml ]; then
    sed -i 's/disable_apparmor = false/disable_apparmor = true/g' ../etc/config.toml
  fi
  warn "apparmor_parser not found; disabled apparmor in containerd config"
fi

log "preflight checks passed"

