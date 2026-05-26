#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1
source common.sh

bash init-shim.sh
bash init-kube.sh

log "rootfs initialized"

