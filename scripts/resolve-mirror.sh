#!/bin/bash
# ==========================================================================
# resolve-mirror.sh — Return the best Ubuntu mirror URL
#
# Priority:
#   1. Local apt-cacher-ng (if running) — cached, no network for repeat builds
#   2. USTC mirror — fast domestic mirror
#
# Usage:  MIRROR=$(scripts/resolve-mirror.sh)
#         echo $MIRROR  →  http://localhost:3142  (if cache available)
# ==========================================================================

DEFAULT_MIRROR="https://mirrors.ustc.edu.cn/ubuntu-ports/"

if systemctl is-active --quiet apt-cacher-ng 2>/dev/null; then
    # apt-cacher-ng shares host network with chroot, localhost works
    echo "http://localhost:3142"
else
    echo "${DEFAULT_MIRROR}"
fi
