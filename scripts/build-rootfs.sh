#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

kubernetes_version=""
arch="$(uname -m)"
image=""
push=false
workdir=""

containerd_version="${CONTAINERD_VERSION:-v2.3.1}"
runc_version="${RUNC_VERSION:-v1.4.2}"
crictl_version=""
nerdctl_version="${NERDCTL_VERSION:-v2.3.1}"
registry_version="${REGISTRY_VERSION:-3.1.1}"
sealos_version="${SEALOS_VERSION:-latest}"
sealos_bin_dir="${SEALOS_BIN_DIR:-}"
lvscare_image="${LVSCARE_IMAGE:-ghcr.io/labring/lvscare:latest}"
sandbox_image=""
all_images=false
conntrack_bin="${CONNTRACK_BIN:-}"
lsof_bin="${LSOF_BIN:-}"

usage() {
  cat <<EOF
Usage: sudo $0 --kubernetes-version v1.36.1 --arch amd64 --image ghcr.io/org/repo/kubernetes:v1.36.1-amd64 [flags]

Required:
  --kubernetes-version VERSION   Kubernetes version, e.g. v1.36.1
  --arch ARCH                    amd64 or arm64
  --image IMAGE                  target image name

Flags:
  --push                         push after build
  --workdir DIR                  use an existing work directory
  --containerd-version VERSION   default: $containerd_version
  --runc-version VERSION         default: $runc_version
  --crictl-version VERSION       default: same as Kubernetes minor
  --nerdctl-version VERSION      default: $nerdctl_version
  --registry-version VERSION     default: $registry_version
  --sealos-version VERSION       latest or release version, default: $sealos_version
  --sealos-bin-dir DIR           directory containing sealos/image-cri-shim/sealctl
  --lvscare-image IMAGE          label value for lvscare image
  --sandbox-image IMAGE          pause image override, e.g. registry.k8s.io/pause:3.10.1
  --conntrack-bin PATH           optional target-arch conntrack binary
  --lsof-bin PATH                optional target-arch lsof binary
  --all                          pass --all to sealos build image saver
  -h, --help                     show help
EOF
}

normalize_arch() {
  case "$1" in
  x86_64 | amd64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  *)
    echo "unsupported arch: $1" >&2
    exit 1
    ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

download() {
  local url=$1
  local out=$2
  local curl_args=(-fL --retry 8 --retry-all-errors --retry-delay 5)
  if [ -n "${GH_TOKEN:-}" ] && [[ "$url" == https://github.com/* || "$url" == https://api.github.com/* ]]; then
    curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  echo "download $url"
  curl "${curl_args[@]}" -o "$out" "$url"
}

extract_tar_strip() {
  local tarball=$1
  local dest=$2
  local strip=${3:-1}
  mkdir -p "$dest"
  tar -xzf "$tarball" --strip-components "$strip" -C "$dest"
}

latest_github_release() {
  local repo=$1
  local curl_args=(-fsSL)
  if [ -n "${GH_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28")
  fi
  curl "${curl_args[@]}" "https://api.github.com/repos/$repo/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
    head -n 1
}

install_from_candidates() {
  local name=$1
  local dest=$2
  shift 2
  local src
  for src in "$@"; do
    if [ -f "$src" ]; then
      install -D -m 0755 "$src" "$dest"
      return 0
    fi
  done
  echo "cannot find $name in candidates: $*" >&2
  return 1
}

kubernetes_module_version() {
  local version=${1#v}
  local major minor patch
  IFS=. read -r major minor patch _ <<<"$version"
  if [ "$major" != 1 ] || [ -z "$minor" ] || [ -z "$patch" ]; then
    echo "invalid Kubernetes version for Go module mapping: $1" >&2
    return 1
  fi
  echo "v0.${minor}.${patch}"
}

kubernetes_module_go_version() {
  local version=${1#v}
  local major minor patch
  IFS=. read -r major minor patch _ <<<"$version"
  if [ "$major" != 1 ] || [ -z "$minor" ]; then
    echo "invalid Kubernetes version for Go version mapping: $1" >&2
    return 1
  fi
  case "$minor" in
  27 | 28) echo "1.20" ;;
  29) echo "1.21" ;;
  30 | 31) echo "1.22" ;;
  32) echo "1.23.0" ;;
  33 | 34) echo "1.24.0" ;;
  35) echo "1.25.0" ;;
  36) echo "1.26.0" ;;
  *)
    echo "unsupported Kubernetes minor for helper Go version: 1.$minor" >&2
    return 1
    ;;
  esac
}

build_kubeadm_config_helper() {
  local kubernetes_version=$1
  local arch=$2
  local out=$3
  local module_version module_go_version helper_build_dir

  module_version="$(kubernetes_module_version "$kubernetes_version")"
  module_go_version="$(kubernetes_module_go_version "$kubernetes_version")"
  helper_build_dir="$downloads/kubeadm-config-helper-${kubernetes_version}-${arch}"
  rm -rf "$helper_build_dir"
  mkdir -p "$helper_build_dir"

  echo "building kubeadm config helper for linux/$arch with k8s modules $module_version and Go $module_go_version"
  (
    cd "$helper_build_dir"
    go mod init sealos-runtime-helper-build >/dev/null
    go mod edit -go="$module_go_version"
    go mod edit \
      -require="github.com/lingdie/sealos-runtime@v0.0.0" \
      -replace="github.com/lingdie/sealos-runtime=$repo_root" \
      -require="k8s.io/apimachinery@$module_version" \
      -require="k8s.io/kubelet@$module_version" \
      -require="k8s.io/kube-proxy@$module_version"
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -mod=mod -trimpath -ldflags="-s -w" \
      -o "$out" github.com/lingdie/sealos-runtime/cmd/kubeadm-config-gen
  )
}

set_kubefile_env_default() {
  local file=$1
  local key=$2
  local value=$3
  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*" key "=" {
      sub(key "=[^[:space:]\\\\]*", key "=" value)
    }
    { print }
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --kubernetes-version)
    kubernetes_version=$2
    shift 2
    ;;
  --arch)
    arch=$2
    shift 2
    ;;
  --image)
    image=$2
    shift 2
    ;;
  --push)
    push=true
    shift
    ;;
  --workdir)
    workdir=$2
    shift 2
    ;;
  --containerd-version)
    containerd_version=$2
    shift 2
    ;;
  --runc-version)
    runc_version=$2
    shift 2
    ;;
  --crictl-version)
    crictl_version=$2
    shift 2
    ;;
  --nerdctl-version)
    nerdctl_version=$2
    shift 2
    ;;
  --registry-version)
    registry_version=$2
    shift 2
    ;;
  --sealos-version)
    sealos_version=$2
    shift 2
    ;;
  --sealos-bin-dir)
    sealos_bin_dir=$2
    shift 2
    ;;
  --lvscare-image)
    lvscare_image=$2
    shift 2
    ;;
  --sandbox-image)
    sandbox_image=$2
    shift 2
    ;;
  --conntrack-bin)
    conntrack_bin=$2
    shift 2
    ;;
  --lsof-bin)
    lsof_bin=$2
    shift 2
    ;;
  --all)
    all_images=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

[ -n "$kubernetes_version" ] || { usage >&2; exit 2; }
[ -n "$image" ] || { usage >&2; exit 2; }

arch="$(normalize_arch "$arch")"
native_arch="$(normalize_arch "$(uname -m)")"
kubernetes_version="v${kubernetes_version#v}"
kube_no_v="${kubernetes_version#v}"
kube_minor="$(cut -d. -f1,2 <<<"$kube_no_v")"
if [ -z "$crictl_version" ]; then
  crictl_version="v$kube_minor.0"
else
  crictl_version="v${crictl_version#v}"
fi
containerd_version="v${containerd_version#v}"
runc_version="v${runc_version#v}"
nerdctl_version="v${nerdctl_version#v}"

require_cmd curl
require_cmd tar
require_cmd sed
require_cmd awk
require_cmd go
require_cmd sealos

if [ "$(uname -s)" != Linux ]; then
  echo "build-rootfs.sh must run on Linux because it executes Linux kubeadm to resolve component images" >&2
  exit 1
fi

if [ -z "$workdir" ]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sealos-runtime.XXXXXX")"
else
  mkdir -p "$workdir"
  workdir="$(cd "$workdir" && pwd)"
fi

build_context="$workdir/context"
downloads="$workdir/downloads"
rm -rf "$build_context" "$downloads"
mkdir -p "$build_context" "$downloads"

cp "$repo_root/Kubefile" "$build_context/Kubefile"
cp -a "$repo_root/rootfs/." "$build_context/"
mkdir -p "$build_context/bin" "$build_context/cri" "$build_context/opt/sealos/bin" "$build_context/images/shim" "$build_context/etc/sealos"

echo "workdir: $workdir"
echo "context: $build_context"

download "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/kubeadm" "$build_context/bin/kubeadm"
download "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/kubectl" "$build_context/bin/kubectl"
download "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/kubelet" "$build_context/bin/kubelet"
chmod 0755 "$build_context/bin/kubeadm" "$build_context/bin/kubectl" "$build_context/bin/kubelet"

build_kubeadm_config_helper "$kubernetes_version" "$arch" "$build_context/opt/sealos/bin/kubeadm-config-gen"

cat >"$build_context/etc/sealos/runtime.json" <<EOF
{
  "apiVersion": "sealos.io/runtime/v1",
  "kind": "KubernetesRuntime",
  "kubernetesVersion": "$kubernetes_version",
  "cri": "containerd",
  "kubeadmConfigHelper": {
    "path": "/opt/sealos/bin/kubeadm-config-gen",
    "apiVersion": "v1",
    "mode": "sanitize"
  }
}
EOF

containerd_archive="containerd-${containerd_version#v}-linux-${arch}.tar.gz"
download "https://github.com/containerd/containerd/releases/download/${containerd_version}/${containerd_archive}" "$downloads/$containerd_archive"
mkdir -p "$downloads/containerd"
extract_tar_strip "$downloads/$containerd_archive" "$downloads/containerd" 1
tar -C "$downloads/containerd" -czf "$build_context/cri/containerd.tar.gz" .

runc_bin="runc.${arch}"
download "https://github.com/opencontainers/runc/releases/download/${runc_version}/${runc_bin}" "$build_context/cri/runc"
chmod 0755 "$build_context/cri/runc"

crictl_archive="crictl-${crictl_version}-linux-${arch}.tar.gz"
download "https://github.com/kubernetes-sigs/cri-tools/releases/download/${crictl_version}/${crictl_archive}" "$downloads/$crictl_archive"
tar -xzf "$downloads/$crictl_archive" -C "$build_context/cri" crictl
chmod 0755 "$build_context/cri/crictl"

nerdctl_archive="nerdctl-${nerdctl_version#v}-linux-${arch}.tar.gz"
download "https://github.com/containerd/nerdctl/releases/download/${nerdctl_version}/${nerdctl_archive}" "$downloads/$nerdctl_archive"
tar -xzf "$downloads/$nerdctl_archive" -C "$build_context/cri" nerdctl
chmod 0755 "$build_context/cri/nerdctl"

registry_archive="registry_${registry_version}_linux_${arch}.tar.gz"
download "https://github.com/distribution/distribution/releases/download/v${registry_version}/${registry_archive}" "$downloads/$registry_archive"
tar -xzf "$downloads/$registry_archive" -C "$build_context/cri" registry
chmod 0755 "$build_context/cri/registry"

if [ -n "$conntrack_bin" ] && [ -f "$conntrack_bin" ]; then
  install -D -m 0755 "$conntrack_bin" "$build_context/bin/conntrack"
elif [ "$native_arch" = "$arch" ] && command -v conntrack >/dev/null 2>&1; then
  install -D -m 0755 "$(command -v conntrack)" "$build_context/bin/conntrack"
else
  echo "warning: target-arch conntrack not found; kubeadm preflight may require it on target hosts" >&2
fi

if [ -n "$lsof_bin" ] && [ -f "$lsof_bin" ]; then
  install -D -m 0755 "$lsof_bin" "$build_context/opt/lsof"
elif [ "$native_arch" = "$arch" ] && command -v lsof >/dev/null 2>&1; then
  install -D -m 0755 "$(command -v lsof)" "$build_context/opt/lsof"
fi

if [ -z "$sealos_bin_dir" ]; then
  if [ "$sealos_version" = latest ]; then
    sealos_version="$(latest_github_release labring/sealos)"
  else
    sealos_version="v${sealos_version#v}"
  fi
  sealos_archive="sealos_${sealos_version#v}_linux_${arch}.tar.gz"
  if ! download "https://github.com/labring/sealos/releases/download/${sealos_version}/${sealos_archive}" "$downloads/$sealos_archive"; then
    sealos_archive="sealos-${sealos_version#v}-linux-${arch}.tar.gz"
    download "https://github.com/labring/sealos/releases/download/${sealos_version}/${sealos_archive}" "$downloads/$sealos_archive"
  fi
  mkdir -p "$downloads/sealos"
  tar -xzf "$downloads/$sealos_archive" -C "$downloads/sealos"
  sealos_bin_dir="$downloads/sealos"
fi

install_from_candidates image-cri-shim "$build_context/cri/image-cri-shim" \
  "$sealos_bin_dir/image-cri-shim" \
  "$sealos_bin_dir/bin/image-cri-shim" \
  "$sealos_bin_dir/sealos/image-cri-shim"

if install_from_candidates sealctl "$build_context/opt/sealctl" \
  "$sealos_bin_dir/sealctl" \
  "$sealos_bin_dir/bin/sealctl" \
  "$sealos_bin_dir/sealos/sealctl"; then
  :
else
  echo "warning: sealctl not bundled; lifecycle may sync local sealctl during mount" >&2
fi

if command -v openssl >/dev/null 2>&1; then
  htpasswd_line="$(openssl passwd -apr1 passw0rd 2>/dev/null | awk '{print "admin:" $0}')"
else
  htpasswd_line=""
fi
if [ -z "${htpasswd_line:-}" ]; then
  htpasswd_line='admin:$apr1$H6uskkkW$IgXLP6ewTrSuBkTrqE8wj/'
fi
printf '%s\n' "$htpasswd_line" >"$build_context/etc/registry_htpasswd"
chmod 0600 "$build_context/etc/registry_htpasswd"

native_kubeadm="$build_context/bin/kubeadm"
if [ "$native_arch" != "$arch" ]; then
  native_kubeadm="$downloads/kubeadm-linux-$native_arch"
  download "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${native_arch}/kubeadm" "$native_kubeadm"
  chmod 0755 "$native_kubeadm"
fi

pause_image="$(KUBECONFIG=/dev/null "$native_kubeadm" config images list --kubernetes-version "$kubernetes_version" 2>/dev/null | awk '/\/pause:/ {print; exit}')"
if [ -z "$pause_image" ]; then
  pause_image="registry.k8s.io/pause:3.10"
fi
if [ -n "$sandbox_image" ]; then
  pause_image="$sandbox_image"
fi
sandbox_image="${pause_image#*/}"
set_kubefile_env_default "$build_context/Kubefile" sandboxImage "$sandbox_image"

KUBECONFIG=/dev/null "$native_kubeadm" config images list --kubernetes-version "$kubernetes_version" >"$build_context/images/shim/DefaultImageList"
if ! grep -qxF "$pause_image" "$build_context/images/shim/DefaultImageList"; then
  echo "$pause_image" >>"$build_context/images/shim/DefaultImageList"
fi
echo "$lvscare_image" >"$build_context/images/shim/LvscareImageList"

find "$build_context" -type f \( -path '*/bin/*' -o -path '*/cri/*' -o -path '*/opt/*' -o -path '*/scripts/*' \) -exec chmod 0755 {} +

build_flags=(
  --platform "linux/$arch"
  --label "version=$kubernetes_version"
  --label "image=$lvscare_image"
  --env "sandboxImage=$sandbox_image"
  -t "$image"
)

if $all_images; then
  build_flags+=(--all)
fi

echo "building $image for linux/$arch"
(
  cd "$build_context"
  sealos build "${build_flags[@]}" .
)

if $push; then
  echo "pushing $image"
  sealos push "$image"
fi

echo "built $image"
