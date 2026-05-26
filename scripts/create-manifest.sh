#!/usr/bin/env bash
set -Eeuo pipefail

target=""
images=()
push=false

usage() {
  cat <<EOF
Usage: $0 --target ghcr.io/org/repo/kubernetes:v1.36.1 --image ...amd64 --image ...arm64 [--push]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --target)
    target=$2
    shift 2
    ;;
  --image)
    images+=("$2")
    shift 2
    ;;
  --push)
    push=true
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

[ -n "$target" ] || { usage >&2; exit 2; }
[ "${#images[@]}" -gt 0 ] || { usage >&2; exit 2; }

buildah manifest rm "$target" >/dev/null 2>&1 || true
buildah manifest create "$target" "${images[@]}"

if $push; then
  buildah manifest push --all --rm "$target" "docker://$target"
fi

