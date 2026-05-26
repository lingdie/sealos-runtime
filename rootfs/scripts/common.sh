#!/usr/bin/env bash
set -Eeuo pipefail

timestamp() {
  date +"%Y-%m-%d %T"
}

log() {
  printf '\033[36mINFO [%s] >> %s\033[0m\n' "$(timestamp)" "$*"
}

warn() {
  printf '\033[33mWARN [%s] >> %s\033[0m\n' "$(timestamp)" "$*"
}

error() {
  printf '\033[31mERROR [%s] >> %s\033[0m\n' "$(timestamp)" "$*"
  exit 1
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

systemctl_or_warn() {
  if command_exists systemctl; then
    systemctl "$@"
  else
    warn "systemctl is unavailable, skipped: systemctl $*"
  fi
}

enable_and_restart() {
  local unit=$1
  systemctl_or_warn daemon-reload
  systemctl_or_warn enable "$unit"
  systemctl_or_warn restart "$unit"
}

disable_and_stop() {
  local unit=$1
  if command_exists systemctl; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

check_status() {
  local unit
  for unit in "$@"; do
    if ! command_exists systemctl; then
      warn "systemctl is unavailable, cannot verify $unit"
      continue
    fi
    log "checking $unit"
    if systemctl is-active --quiet "$unit"; then
      log "$unit is running"
    else
      systemctl status "$unit" --no-pager || true
      error "$unit is not running"
    fi
  done
}

install_file() {
  local src=$1
  local dst=$2
  local mode=${3:-0644}
  install -D -m "$mode" "$src" "$dst"
}

install_binary() {
  local src=$1
  local dst=$2
  install -D -m 0755 "$src" "$dst"
}

get_distribution() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s' "${ID:-}"
  fi
}

disable_firewalld() {
  local dist
  dist="$(get_distribution | tr '[:upper:]' '[:lower:]')"
  case "$dist" in
  ubuntu | deepin | debian | raspbian)
    command_exists ufw && ufw disable || true
    ;;
  centos | rhel | ol | sles | kylin | neokylin | rocky | almalinux | fedora)
    if command_exists systemctl && systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
      systemctl stop firewalld >/dev/null 2>&1 || true
      systemctl disable firewalld >/dev/null 2>&1 || true
    fi
    ;;
  *)
    if command_exists systemctl && systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
      systemctl stop firewalld >/dev/null 2>&1 || true
      systemctl disable firewalld >/dev/null 2>&1 || true
    fi
    ;;
  esac
}

check_port_inuse() {
  local bin_dir=${BIN_DIR:-/usr/bin}
  if ! command_exists lsof && [ -x ../opt/lsof ]; then
    install_binary ../opt/lsof "$bin_dir/lsof"
  fi
  if ! command_exists lsof; then
    warn "lsof is unavailable, skipped port preflight"
    return 0
  fi

  log "checking Kubernetes reserved ports"
  local port
  for port in {10249..10259} {5050..5054}; do
    if lsof -i :"$port" >/dev/null 2>&1; then
      error "port $port is occupied"
    fi
  done
}

ensure_host_localhost() {
  grep -Eq '(^|[[:space:]])localhost([[:space:]]|$)' /etc/hosts || echo "127.0.0.1 localhost" >>/etc/hosts
  grep -Eq '^::1[[:space:]]+localhost' /etc/hosts || echo "::1 localhost" >>/etc/hosts
}

ensure_selinux_permissive() {
  if [ -s /etc/selinux/config ] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    command_exists setenforce && setenforce 0 || true
  fi
}

strip_port() {
  printf '%s' "${1%%:*}"
}

