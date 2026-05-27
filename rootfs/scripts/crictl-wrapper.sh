#!/usr/bin/env bash
# sealos-runtime crictl wrapper
set -Eeuo pipefail

real_crictl=""
config="${CRI_CONFIG_FILE:-${CONTAINER_RUNTIME_ENDPOINT_CONFIG_PATH:-/etc/crictl.yaml}}"

normalize_endpoint() {
  case "$1" in
  *://*) printf '%s' "$1" ;;
  *) printf 'unix://%s' "$1" ;;
  esac
}

runtime_endpoint="$(normalize_endpoint "${CONTAINER_RUNTIME_ENDPOINT:-${SEALOS_SYS_CRI_ENDPOINT:-/run/containerd/containerd.sock}}")"
image_endpoint="$(normalize_endpoint "${IMAGE_SERVICE_ENDPOINT:-${SEALOS_SYS_IMAGE_ENDPOINT:-/var/run/image-cri-shim.sock}}")"

for candidate in \
  "${CRICTL_REAL:-}" \
  "$(dirname "$0")/crictl.real" \
  /usr/bin/crictl.real \
  /usr/local/bin/crictl.real; do
  [ -n "$candidate" ] || continue
  if [ -x "$candidate" ]; then
    real_crictl="$candidate"
    break
  fi
done

if [ ! -x "$real_crictl" ]; then
  echo "crictl real binary not found" >&2
  exit 127
fi

args=()
has_config=false
has_runtime_endpoint=false
has_image_endpoint=false

for arg in "$@"; do
  case "$arg" in
  -c | -c=* | --config | --config=*)
    has_config=true
    ;;
  -r | -r=* | --runtime-endpoint | --runtime-endpoint=*)
    has_runtime_endpoint=true
    ;;
  -i | -i=* | --image-endpoint | --image-endpoint=*)
    has_image_endpoint=true
    ;;
  esac
done

if ! $has_config && [ -f "$config" ]; then
  args+=(--config "$config")
fi

if ! $has_runtime_endpoint; then
  args+=(--runtime-endpoint "$runtime_endpoint")
fi

if ! $has_image_endpoint; then
  args+=(--image-endpoint "$image_endpoint")
fi

exec "$real_crictl" "${args[@]}" "$@"
