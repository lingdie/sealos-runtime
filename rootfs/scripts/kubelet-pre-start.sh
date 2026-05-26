#!/usr/bin/env bash
set -Eeuo pipefail

for module in bridge ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh br_netfilter; do
  modprobe "$module" >/dev/null 2>&1 || true
done

if ! modprobe nf_conntrack >/dev/null 2>&1; then
  modprobe nf_conntrack_ipv4 >/dev/null 2>&1 || true
fi

sysctl --system >/dev/null 2>&1 || true
swapoff --all || true

if [ -s /etc/selinux/config ] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
  sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
  command -v setenforce >/dev/null 2>&1 && setenforce 0 || true
fi

