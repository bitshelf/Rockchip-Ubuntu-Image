#!/bin/bash
# ==========================================================================
# cross-build-all.sh — Cross-build all Rockchip-patched arm64 packages
#
# Ubuntu official method: QEMU arm64 chroot → native dpkg-buildpackage
# Per "amd64 Host → arm64 Target" section of .rules:
#   "Package rebuild: sbuild --host=arm64 with QEMU chroot (Ubuntu official)"
#   This script uses debootstrap+QEMU chroot (same effect, no sbuild schroot needed)
#
# Package build order (dependency-aware, from PACKAGES.txt):
#   Critical: libdrm, wayland
#   High:     weston, xserver
#   Medium:   v4l-utils, mpv
#   Low:      blueman, cheese, wireplumber, openbox, pcmanfm
#
# Usage: ./scripts/cross-build-all.sh [package1 package2 ...]
#        ./scripts/cross-build-all.sh              # build all
#        ./scripts/cross-build-all.sh libdrm mpv   # build specific packages
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHROOT="${CHROOT:-/tmp/rk-arm64-noble}"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/ubuntu/rockchip-debs}"
PATCHES="${SCRIPT_DIR}/patches/userland"
MIRROR="${MIRROR:-https://mirrors.ustc.edu.cn/ubuntu-ports/}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Source package name mapping (package tag → Ubuntu source package)
declare -A SRC_MAP=(
    [libdrm]=libdrm
    [wayland]=wayland
    [weston]=weston
    [xserver]=xorg-server
    [v4l-utils]=v4l-utils
    [mpv]=mpv
    [blueman]=blueman
    [cheese]=cheese
    [openbox]=openbox
    [pcmanfm]=pcmanfm
    [wireplumber]=wireplumber
)

# Build order (dependency-aware)
BUILD_ORDER=(
    libdrm wayland weston xserver
    v4l-utils mpv
    blueman cheese wireplumber openbox pcmanfm
)

mkdir -p "$OUTPUT"

# ==========================================================================
# Setup: create noble arm64 chroot (once)
# ==========================================================================
setup_chroot() {
    if [[ -d "$CHROOT/usr/bin" ]]; then
        info "Chroot already exists at $CHROOT, skipping creation"
    else
        info "Creating noble arm64 chroot at $CHROOT..."
        sudo rm -rf "$CHROOT"
        sudo debootstrap --arch arm64 noble "$CHROOT" "$MIRROR" 2>&1 | tail -5
        sudo cp /usr/bin/qemu-aarch64-static "$CHROOT/usr/bin/"
        info "Chroot created successfully"
    fi

    # Install/update build tools
    info "Installing build tools in chroot..."
    sudo chroot "$CHROOT" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | tail -1
    apt-get install -y -qq build-essential dpkg-dev devscripts ubuntu-dev-tools fakeroot 2>&1 | tail -2
    '
}

# ==========================================================================
# Find the best patch directory for a package
# Priority: noble/ > version-specific subdir/ > flat patches in pkg dir
# ==========================================================================
find_patch_dir() {
    local pkg="$1"
    local base="${PATCHES}/${pkg}"

    [[ ! -d "$base" ]] && { echo ""; return; }

    # 1. noble/ subdirectory (Ubuntu 24.04 adapted patches)
    if [[ -d "$base/noble" ]] && ls "$base/noble/"*.patch &>/dev/null 2>&1; then
        echo "$base/noble"
        return
    fi

    # 2. Flat patches at top level
    if ls "$base/"*.patch &>/dev/null 2>&1; then
        echo "$base"
        return
    fi

    # 3. Any version subdirectory with patches
    local sub
    sub=$(find "$base" -mindepth 2 -maxdepth 2 -name "*.patch" -type f -print -quit 2>/dev/null | xargs dirname 2>/dev/null)
    if [[ -n "$sub" ]]; then
        echo "$sub"
        return
    fi

    echo ""
}

# ==========================================================================
# Rebuild a single package
# ==========================================================================
rebuild_package() {
    local pkg="$1"
    local src="${SRC_MAP[$pkg]:-$pkg}"
    local patch_dir
    patch_dir=$(find_patch_dir "$pkg")

    echo ""
    info "========== Rebuilding: $pkg (src: $src) =========="
    info "Patch dir: ${patch_dir:-none}"

    # Copy patches into chroot
    sudo mkdir -p "$CHROOT/build"
    sudo rm -rf "$CHROOT/build/patches"
    if [[ -n "$patch_dir" && -d "$patch_dir" ]]; then
        sudo cp -r "$patch_dir" "$CHROOT/build/patches"
    fi

    # Build inside chroot
    local rc=0
    sudo chroot "$CHROOT" bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /build
rm -rf /build/src /build/*.deb

# Get source
echo '--- Getting source for $src (noble) ---'
pull-lp-source $src noble 2>&1 | tail -3
srcdir=\$(find /build -maxdepth 1 -type d -name '${src}-*' | head -1)
if [[ -z \"\$srcdir\" ]]; then
    echo 'ERROR: source directory not found for $src'
    exit 1
fi
cd \"\$srcdir\"
echo \"Source: \$(pwd)\"

# Apply Rockchip patches
if [[ -d /build/patches ]]; then
    applied=0; failed=0
    for pf in \$(find /build/patches -maxdepth 1 -name '*.patch' -type f | sort); do
        if patch -p1 -N --dry-run < \"\$pf\" 2>/dev/null; then
            patch -p1 < \"\$pf\" 2>/dev/null
            applied=\$((applied + 1))
            echo \"  APPLIED: \$(basename \$pf)\"
        else
            echo \"  FAILED: \$(basename \$pf)\"
            failed=\$((failed + 1))
        fi
    done
    echo \"Patches: \$applied applied, \$failed failed\"
else
    echo 'No patches to apply'
fi

# Install build dependencies
echo '--- Installing build dependencies ---'
apt-get build-dep -y -qq $src 2>&1 | tail -5 || {
    echo 'WARNING: build-dep failed, trying mk-build-deps fallback'
    mk-build-deps --install --remove --root-cmd sudo --tool 'apt-get -y -qq' debian/control 2>&1 | tail -5 || true
}

# Build natively (arm64)
echo '--- Building $pkg for arm64 ---'
dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -20
" || rc=$?

    # Collect .debs
    local deb_count
    deb_count=$(sudo find "$CHROOT/build" -maxdepth 1 -name "*.deb" -type f | wc -l)
    if [[ "$deb_count" -gt 0 ]]; then
        sudo find "$CHROOT/build" -maxdepth 1 -name "*.deb" -type f -exec cp -v {} "$OUTPUT/" \;
        info "$pkg: $deb_count .deb(s) copied to $OUTPUT"
    else
        warn "$pkg: no .deb files produced (rc=$rc)"
        return 1
    fi
}

# ==========================================================================
# Main
# ==========================================================================
info "================================================"
info "Rockchip arm64 Cross-Build (Ubuntu Official Method)"
info "  Host:   $(dpkg --print-architecture) ($(uname -m))"
info "  Target: arm64 (noble)"
info "  Output: $OUTPUT"
info "================================================"

setup_chroot

# Determine which packages to build
if [[ $# -gt 0 ]]; then
    PACKAGES=("$@")
else
    PACKAGES=("${BUILD_ORDER[@]}")
fi

info "Packages to build: ${PACKAGES[*]}"
echo ""

built=0 failed=0 skipped=0
for pkg in "${PACKAGES[@]}"; do
    if [[ -z "${SRC_MAP[$pkg]:-}" ]]; then
        warn "Unknown package: $pkg (no source mapping), skipping"
        skipped=$((skipped + 1))
        continue
    fi
    if rebuild_package "$pkg"; then
        built=$((built + 1))
    else
        failed=$((failed + 1))
    fi
done

echo ""
info "================================================"
info "Build summary: $built succeeded, $failed failed, $skipped skipped"
info "Output directory: $OUTPUT"
ls -lh "$OUTPUT/" 2>/dev/null || warn "No packages in output"
info "================================================"

exit $failed
