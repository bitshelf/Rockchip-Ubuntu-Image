#!/bin/bash
# ==========================================================================
# build-in-container.sh — Runs inside the arm64 Docker container
#
# Builds a single Rockchip-patched package natively (arm64).
# Called via: docker exec rk-arm64-builder /build.sh <pkg> <src> [series]
# ==========================================================================
set -euo pipefail

PKG="${1:?usage: $0 <pkg-tag> <src-pkg> [series]}"
SRC="${2:?}"
SERIES="${3:-noble}"
WORKDIR="/tmp/build-${PKG}"

export DEBIAN_FRONTEND=noninteractive

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=== Building $PKG (source: $SRC, series: $SERIES) ==="
echo "Arch: $(dpkg --print-architecture) / $(uname -m)"
echo "QEMU_CPU: ${QEMU_CPU:-default}"

# Get source
echo "--- Getting source ---"
pull-lp-source "$SRC" "$SERIES" 2>&1 | tail -5
srcdir=$(find "$WORKDIR" -maxdepth 1 -type d -name "${SRC}-*" | head -1)
if [[ -z "$srcdir" ]]; then
    echo "ERROR: source directory not found for $SRC"
    exit 1
fi
cd "$srcdir"
echo "Source: $(pwd)"

# Find and apply patches
# Priority: noble/ > version-subdir > flat
if [[ -d "/patches/$PKG/noble" ]] && ls "/patches/$PKG/noble/"*.patch &>/dev/null 2>&1; then
    PATCH_DIR="/patches/$PKG/noble"
elif ls "/patches/$PKG/"*.patch &>/dev/null 2>&1; then
    PATCH_DIR="/patches/$PKG"
else
    PATCH_DIR=$(find "/patches/$PKG" -mindepth 2 -maxdepth 2 -name "*.patch" -type f -print -quit 2>/dev/null | xargs dirname 2>/dev/null || echo "")
fi

if [[ -n "${PATCH_DIR:-}" && -d "${PATCH_DIR:-}" ]]; then
    applied=0; failed=0
    echo "--- Applying patches from ${PATCH_DIR} ---"
    for pf in $(find "$PATCH_DIR" -maxdepth 1 -name "*.patch" -type f | sort); do
        if patch -p1 -N --dry-run < "$pf" 2>/dev/null; then
            patch -p1 < "$pf" 2>/dev/null
            applied=$((applied + 1))
            echo "  OK: $(basename $pf)"
        else
            echo "  FAIL: $(basename $pf)"
            failed=$((failed + 1))
        fi
    done
    echo "Patches: $applied applied, $failed failed"
else
    echo "No patches found for $PKG"
fi

# Install build dependencies
echo "--- Installing build dependencies ---"
apt-get build-dep -y -qq "$SRC" 2>&1 | tail -5 || {
    echo "WARNING: build-dep failed, trying alternate methods..."
    # Try mk-build-deps
    if [[ -f debian/control ]]; then
        apt-get install -y -qq equivs 2>&1 | tail -1
        mk-build-deps --install --remove --tool 'apt-get -y -o APT::Get::Assume-Yes=true' debian/control 2>&1 | tail -5 || true
    fi
    # Last resort: try to install what we can
    apt-get build-dep -d -y "$SRC" 2>&1 | tail -3 || true
}

# Build
echo "--- Building ---"
DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-nocheck parallel=$(nproc)}"
export DEB_BUILD_OPTIONS
dpkg-buildpackage -us -uc -b -j"$(nproc)" 2>&1 | tail -30

# Collect debs
echo "--- Collecting .debs ---"
find "$WORKDIR" -maxdepth 1 -name "*.deb" -type f -exec ls -lh {} \;
find "$WORKDIR" -maxdepth 1 -name "*.deb" -type f -exec cp -v {} /output/ \;
echo "=== $PKG: $(find "$WORKDIR" -maxdepth 1 -name '*.deb' | wc -l) debs built ==="
