#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

registry_domain=${1:-sealos.hub}
registry_port=${2:-5000}
bin_dir=${BIN_DIR:-/usr/bin}

mkdir -p /etc/containerd/certs.d "$bin_dir"

if [ -f ../cri/libseccomp.tar.gz ]; then
  mkdir -p /opt/containerd
  tar -zxf ../cri/libseccomp.tar.gz -C /opt/containerd
  echo "/opt/containerd/lib" >/etc/ld.so.conf.d/containerd.conf
  command_exists ldconfig && ldconfig || true
fi

install_file ../etc/containerd.service /etc/systemd/system/containerd.service
tar -zxf ../cri/containerd.tar.gz -C "$bin_dir"

if [ -f ../cri/runc ]; then
  install_binary ../cri/runc "$bin_dir/runc"
fi

if [ -f ../cri/crictl ]; then
  install_binary ../cri/crictl "$bin_dir/crictl"
fi

if [ -f ../cri/nerdctl ]; then
  install_binary ../cri/nerdctl "$bin_dir/nerdctl"
fi

install_file ../etc/config.toml /etc/containerd/config.toml
install_file ../etc/hosts.toml "/etc/containerd/certs.d/$registry_domain:$registry_port/hosts.toml"
install_file ../etc/crictl.yaml /etc/crictl.yaml

enable_and_restart containerd.service
check_status containerd.service
log "containerd runtime initialized"

