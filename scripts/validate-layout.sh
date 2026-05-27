#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

required_scripts=(
  check.sh
  init-cri.sh
  clean-cri.sh
  init-registry.sh
  clean-registry.sh
  init.sh
  clean.sh
  init-kube.sh
  clean-kube.sh
  init-shim.sh
  clean-shim.sh
  kubelet-pre-start.sh
  kubelet-post-stop.sh
  crictl-wrapper.sh
  common.sh
)

required_templates=(
  config.toml.tmpl
  containerd.service.tmpl
  crictl.yaml.tmpl
  hosts.toml.tmpl
  image-cri-shim.service.tmpl
  image-cri-shim.yaml.tmpl
  kubelet.service.tmpl
  registry.service.tmpl
  registry_config.yml.tmpl
  registry.yml.tmpl
)

fail() {
  echo "validate-layout: $*" >&2
  exit 1
}

for script in "${required_scripts[@]}"; do
  path="$repo_root/rootfs/scripts/$script"
  [ -f "$path" ] || fail "missing script $path"
  [ -x "$path" ] || fail "script is not executable: $path"
done

for template in "${required_templates[@]}"; do
  [ -f "$repo_root/rootfs/etc/$template" ] || fail "missing template rootfs/etc/$template"
done

for label in init clean check init-cri clean-cri init-registry clean-registry; do
  grep -q "${label}=" "$repo_root/Kubefile" || fail "Kubefile missing label $label"
done

grep -q 'sealos.io.type="rootfs"' "$repo_root/Kubefile" || fail "Kubefile must declare rootfs type"
grep -q 'sealos.io.distribution="kubernetes"' "$repo_root/Kubefile" || fail "Kubefile must declare kubernetes distribution"
grep -q 'SEALOS_SYS_CRI_ENDPOINT=/var/run/containerd/containerd.sock' "$repo_root/Kubefile" || fail "unexpected CRI endpoint"
grep -q 'SEALOS_SYS_IMAGE_ENDPOINT=/var/run/image-cri-shim.sock' "$repo_root/Kubefile" || fail "unexpected image endpoint"
grep -q 'address = "/run/containerd/containerd.sock"' "$repo_root/rootfs/etc/config.toml.tmpl" || fail "containerd socket must match tmp/runtime"
grep -q 'runtime-endpoint: unix:///run/containerd/containerd.sock' "$repo_root/rootfs/etc/crictl.yaml.tmpl" || fail "crictl runtime endpoint must match tmp/runtime"
grep -q 'SystemdCgroup = true' "$repo_root/rootfs/etc/config.toml.tmpl" || fail "containerd cgroup driver must match tmp/runtime"
grep -q 'proxy:' "$repo_root/rootfs/etc/registry_config.yml.tmpl" || fail "registry proxy config must match tmp/runtime"

expected_minors="1.27 1.28 1.29 1.30 1.31 1.32 1.33 1.34 1.35 1.36"
actual_minors="$(grep -vE '^\s*(#|$)' "$repo_root/.github/versions/supported-minors.txt" | xargs)"
[ "$actual_minors" = "$expected_minors" ] || fail "supported minors mismatch: $actual_minors"

bash -n "$repo_root"/scripts/*.sh "$repo_root"/rootfs/scripts/*.sh

echo "layout ok"
