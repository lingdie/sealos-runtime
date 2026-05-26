#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bash clean-kube.sh
bash clean-shim.sh

log "rootfs cleaned"

