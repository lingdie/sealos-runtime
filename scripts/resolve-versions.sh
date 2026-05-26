#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
minor_file="$repo_root/.github/versions/supported-minors.txt"
arches="amd64,arm64"
kubernetes_versions=()
matrix=false
versions_only=false

runner_for_arch() {
  case "$1" in
  amd64) echo "ubuntu-24.04" ;;
  arm64) echo "ubuntu-24.04-arm" ;;
  *)
    echo "unsupported arch: $1" >&2
    exit 1
    ;;
  esac
}

normalize_arch() {
  case "$1" in
  amd64 | x86_64) echo amd64 ;;
  arm64 | aarch64) echo arm64 ;;
  *)
    echo "unsupported arch: $1" >&2
    exit 1
    ;;
  esac
}

normalize_kubernetes_version() {
  local version=$1
  version="v${version#v}"
  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid Kubernetes version: $1" >&2
    exit 1
  fi
  echo "$version"
}

minor_for_version() {
  local version=$1
  version="${version#v}"
  IFS=. read -r major minor _patch <<<"$version"
  printf '%s.%s\n' "$major" "$minor"
}

minor_supported() {
  local wanted=$1
  local minor
  while IFS= read -r minor || [ -n "$minor" ]; do
    minor="${minor%%#*}"
    minor="$(printf '%s' "$minor" | xargs)"
    [ -n "$minor" ] || continue
    [ "$minor" = "$wanted" ] && return 0
  done <"$minor_file"
  return 1
}

fetch_stable_version() {
  local minor=$1
  curl -fsSL --retry 5 --retry-delay 2 "https://dl.k8s.io/release/stable-${minor}.txt"
}

usage() {
  cat <<EOF
Usage: $0 [flags]

Flags:
  --minor-file PATH     supported minors file (default: $minor_file)
  --arches LIST         comma-separated arch list for matrix output (default: $arches)
  --kubernetes-version VERSION
                        explicit Kubernetes patch version. May be passed more than once.
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
  --kubernetes-version | --version)
    kubernetes_versions+=("$(normalize_kubernetes_version "$2")")
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
if [ "${#kubernetes_versions[@]}" -gt 0 ]; then
  for version in "${kubernetes_versions[@]}"; do
    minor="$(minor_for_version "$version")"
    if ! minor_supported "$minor"; then
      echo "unsupported Kubernetes minor for this runtime: $version" >&2
      exit 1
    fi
    versions+=("$version")
  done
else
  while IFS= read -r minor || [ -n "$minor" ]; do
    minor="${minor%%#*}"
    minor="$(printf '%s' "$minor" | xargs)"
    [ -n "$minor" ] || continue
    version="$(fetch_stable_version "$minor")"
    case "$version" in
    v"$minor".*) ;;
    *)
      echo "unexpected stable version for $minor: $version" >&2
      exit 1
      ;;
    esac
    versions+=("$version")
  done <"$minor_file"
fi

arch_array=()
IFS=',' read -r -a raw_arch_array <<<"$arches"
for arch in "${raw_arch_array[@]}"; do
  arch="$(printf '%s' "$arch" | xargs)"
  [ -n "$arch" ] || continue
  arch_array+=("$(normalize_arch "$arch")")
done

if [ "${#arch_array[@]}" -eq 0 ]; then
  echo "no architectures selected" >&2
  exit 1
fi

if [ "${#versions[@]}" -eq 0 ]; then
  echo "no Kubernetes versions selected" >&2
  exit 1
fi

if $matrix; then
  printf '{"include":['
  first=true
  for version in "${versions[@]}"; do
    for arch in "${arch_array[@]}"; do
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

if $versions_only; then
  printf '%s\n' "${versions[@]}"
  exit 0
fi

for version in "${versions[@]}"; do
  echo "$version"
done
