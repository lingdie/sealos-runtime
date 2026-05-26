#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bin_dir=${BIN_DIR:-/usr/bin}

ensure_host_localhost
disable_firewalld
ensure_selinux_permissive

install_binary ../scripts/kubelet-pre-start.sh "$bin_dir/kubelet-pre-start.sh"
install_binary ../scripts/kubelet-post-stop.sh "$bin_dir/kubelet-post-stop.sh"

if [ -d ../etc/sysctl.d ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    printf '%s=%s # sealos\n' "$key" "$value"
  done < <(cat ../etc/sysctl.d/*.conf 2>/dev/null | sort -u) >>/etc/sysctl.conf
fi

"$bin_dir/kubelet-pre-start.sh" || true

sealos_b='### sealos begin ###'
sealos_e='### sealos end ###'
if ! grep -E "($sealos_b|$sealos_e)" /etc/security/limits.conf >/dev/null 2>&1; then
  {
    echo "$sealos_b"
    grep -hvE '^\s*(#|$)' ../etc/limits.d/*.conf 2>/dev/null || true
    echo "$sealos_e"
  } >>/etc/security/limits.conf
fi

install_binary ../bin/kubeadm "$bin_dir/kubeadm"
install_binary ../bin/kubectl "$bin_dir/kubectl"
install_binary ../bin/kubelet "$bin_dir/kubelet"

if [ -f ../bin/conntrack ]; then
  install_binary ../bin/conntrack "$bin_dir/conntrack"
fi

if command_exists crictl; then
  if [ -n "${registryDomain:-}" ] && [ -n "${registryPort:-}" ] && [ -n "${sandboxImage:-}" ]; then
    log "pulling pause image ${registryDomain}:${registryPort}/${sandboxImage}"
    crictl pull "${registryDomain}:${registryPort}/${sandboxImage}" || warn "pause image pull failed; kubeadm may retry later"
  fi
fi

install_file ../etc/kubelet.service /etc/systemd/system/kubelet.service
mkdir -p /etc/systemd/system/kubelet.service.d
cp -a ../etc/systemd/system/kubelet.service.d/. /etc/systemd/system/kubelet.service.d/
mkdir -p /var/lib/kubelet /etc/kubernetes /var/log/kubernetes
[ -f ../statics/audit-policy.yml ] && install_file ../statics/audit-policy.yml /etc/kubernetes/audit-policy.yml

systemctl_or_warn daemon-reload
systemctl_or_warn enable kubelet.service
log "kubelet initialized"

