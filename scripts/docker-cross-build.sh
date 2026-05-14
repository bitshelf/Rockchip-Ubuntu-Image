#!/bin/bash
set -euo pipefail
# ==========================================================================
# docker-cross-build.sh — Cross-build arm64 packages via sbuild (Ubuntu official)
#
# Uses sbuild with QEMU arm64 chroot or native arm64 host.
# On amd64: sbuild --host=arm64 with arm64 schroot
# On arm64: native dpkg-buildpackage
# ==========================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${SCRIPT_DIR}/ubuntu/rockchip-debs"
PATCHES="${SCRIPT_DIR}/patches/userland"
ARCH="${ARCH:-$(dpkg --print-architecture)}"

echo "=== Host architecture: $ARCH ==="

mkdir -p "$OUTPUT"

if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    # Native ARM64 build
    echo "Native arm64 build"
    sudo apt-get update -qq
    sudo apt-get install -y -qq dpkg-dev ubuntu-dev-tools debhelper devscripts

    for pkg in libdrm wayland; do
        echo "=== Native build: $pkg ==="
        mkdir -p /tmp/rebuild && cd /tmp/rebuild
        pull-lp-source "$pkg" noble 2>&1 | tail -3
        srcdir=$(find /tmp/rebuild -maxdepth 1 -type d -name "${pkg}-*" | head -1)
        cd "$srcdir"

        # Apply patches
        for pf in $(find "$PATCHES/$pkg" -name "*.patch" -type f 2>/dev/null | sort); do
            patch -p1 -N < "$pf" 2>/dev/null || echo "  SKIP: $(basename $pf)"
        done

        # Native build
        sudo apt-get build-dep -y -qq "$pkg" 2>&1 | tail -1
        dpkg-buildpackage -us -uc -b -j$(nproc) 2>&1 | tail -5
        cp /tmp/rebuild/*.deb "$OUTPUT/" 2>/dev/null || true
    done
else
    # amd64: use Docker with ubuntu:noble + sbuild
    echo "=== amd64 cross-build via Docker + sbuild ==="
    docker run --rm --privileged \
      -v "${SCRIPT_DIR}:/workspace" -v "${OUTPUT}:/output" \
      ubuntu:noble bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq sbuild schroot ubuntu-dev-tools qemu-user-static

        # Setup sbuild arm64 schroot
        [[ -f /var/lib/sbuild/noble-arm64.tar.gz ]] || {
            mk-sbuild --arch=arm64 noble 2>&1 | tail -5
        }

        for pkg in libdrm wayland; do
            echo "=== sbuild: $pkg ==="
            mkdir -p /tmp/rebuild && cd /tmp/rebuild
            pull-lp-source "$pkg" noble 2>&1 | tail -2
            srcdir=$(find /tmp/rebuild -maxdepth 1 -type d -name "${pkg}-*" | head -1)
            cd "$srcdir"

            # Apply patches
            for pf in $(find "/workspace/patches/userland/$pkg" -name "*.patch" -type f 2>/dev/null | sort); do
                patch -p1 -N < "$pf" 2>/dev/null || true
            done

            cd /tmp/rebuild
            # Build via sbuild --host=arm64
            sbuild --host=arm64 -d noble --no-run-lintian 2>&1 | tail -10
            cp /tmp/rebuild/*.deb /output/ 2>/dev/null || true
        done
    ' || echo "Docker/sbuild failed — consider using arm64 native build"
fi

echo "=== Output ==="
ls -lh "$OUTPUT/"
