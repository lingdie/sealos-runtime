#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sealos-runtime-helper-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

build_helper() {
  local kubernetes_version=$1
  local out=$2
  local version=${kubernetes_version#v}
  local major minor patch module_version module_go_version build_dir
  IFS=. read -r major minor patch _ <<<"$version"
  if [ "$major" != 1 ] || [ -z "$minor" ] || [ -z "$patch" ]; then
    echo "invalid Kubernetes version: $kubernetes_version" >&2
    return 1
  fi
  module_version="v0.${minor}.${patch}"
  case "$minor" in
  27 | 28) module_go_version="1.20" ;;
  29) module_go_version="1.21" ;;
  30 | 31) module_go_version="1.22" ;;
  32) module_go_version="1.23.0" ;;
  33 | 34) module_go_version="1.24.0" ;;
  35) module_go_version="1.25.0" ;;
  36) module_go_version="1.26.0" ;;
  *)
    echo "unsupported Kubernetes minor for helper Go version: 1.$minor" >&2
    return 1
    ;;
  esac
  build_dir="$tmpdir/$kubernetes_version"
  mkdir -p "$build_dir"
  (
    cd "$build_dir"
    go mod init "helper-test-${minor}" >/dev/null
    go mod edit -go="$module_go_version"
    go mod edit \
      -require="github.com/lingdie/sealos-runtime@v0.0.0" \
      -replace="github.com/lingdie/sealos-runtime=$repo_root" \
      -require="k8s.io/apimachinery@$module_version" \
      -require="k8s.io/kubelet@$module_version" \
      -require="k8s.io/kube-proxy@$module_version"
    go build -mod=mod -trimpath -o "$out" github.com/lingdie/sealos-runtime/cmd/kubeadm-config-gen
  )
}

input="$tmpdir/config.yaml"
cat >"$input" <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
containerLogMaxWorkers: 1
containerLogMonitorInterval: 10s
logging:
  format: text
  options:
    json:
      infoBufferSize: "0"
    text:
      infoBufferSize: "0"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 32768
  tcpBeLiberal: false
  udpStreamTimeout: 0s
  udpTimeout: 0s
logging:
  format: text
nftables:
  masqueradeBit: 14
EOF

helper127="$tmpdir/kubeadm-config-gen-127"
helper130="$tmpdir/kubeadm-config-gen-130"
build_helper v1.27.16 "$helper127"
build_helper v1.30.14 "$helper130"

out127="$("$helper127" sanitize --kubernetes-version v1.27.16 --helper-api v1 <"$input")"
out130="$("$helper130" sanitize --kubernetes-version v1.30.14 --helper-api v1 <"$input")"

for removed in containerLogMaxWorkers containerLogMonitorInterval tcpBeLiberal udpStreamTimeout udpTimeout nftables; do
  if grep -q "$removed" <<<"$out127"; then
    echo "v1.27 helper should remove $removed" >&2
    exit 1
  fi
done
for preserved in containerRuntimeEndpoint format: json: maxPerCore; do
  if ! grep -q "$preserved" <<<"$out127"; then
    echo "v1.27 helper should preserve $preserved" >&2
    exit 1
  fi
done
for preserved in containerLogMaxWorkers containerLogMonitorInterval tcpBeLiberal udpStreamTimeout udpTimeout logging nftables; do
  if ! grep -q "$preserved" <<<"$out130"; then
    echo "v1.30 helper should preserve $preserved" >&2
    exit 1
  fi
done

echo "versioned helper ok"
