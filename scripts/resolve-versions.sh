#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
minor_file="$repo_root/.github/versions/supported-minors.txt"
arches="amd64,arm64"
matrix=false
versions_only=false

runner_for_arch() {
  case "$1" in
  amd64) echo "ubuntu-24.04" ;;
  arm64) echo "ubuntu-24.04-arm" ;;
  *) echo "ubuntu-24.04" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $0 [flags]

Flags:
  --minor-file PATH     supported minors file (default: $minor_file)
  --arches LIST         comma-separated arch list for matrix output (default: $arches)
  --matrix              print GitHub Actions matrix JSON
  --versions-only       print one Kubernetes version per line
  -h, --help            show help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --minor-file)
    minor_file=$2
    shift 2
    ;;
  --arches)
    arches=$2
    shift 2
    ;;
  --matrix)
    matrix=true
    shift
    ;;
  --versions-only)
    versions_only=true
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

if [ ! -f "$minor_file" ]; then
  echo "minor file not found: $minor_file" >&2
  exit 1
fi

versions=()
while IFS= read -r minor || [ -n "$minor" ]; do
  minor="${minor%%#*}"
  minor="$(printf '%s' "$minor" | xargs)"
  [ -n "$minor" ] || continue
  version="$(curl -fsSL "https://dl.k8s.io/release/stable-${minor}.txt")"
  case "$version" in
  v"$minor".*) ;;
  *)
    echo "unexpected stable version for $minor: $version" >&2
    exit 1
    ;;
  esac
  versions+=("$version")
done <"$minor_file"

if $versions_only; then
  printf '%s\n' "${versions[@]}"
  exit 0
fi

if $matrix; then
  IFS=',' read -r -a arch_array <<<"$arches"
  printf '{"include":['
  first=true
  for version in "${versions[@]}"; do
    for arch in "${arch_array[@]}"; do
      arch="$(printf '%s' "$arch" | xargs)"
      [ -n "$arch" ] || continue
      if ! $first; then
        printf ','
      fi
      first=false
      printf '{"kubernetes":"%s","arch":"%s","runner":"%s"}' "$version" "$arch" "$(runner_for_arch "$arch")"
    done
  done
  printf ']}\n'
  exit 0
fi

for version in "${versions[@]}"; do
  echo "$version"
done
