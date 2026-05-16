#!/bin/bash
set -euo pipefail
# ==========================================================================
# rebuild-in-chroot.sh — Rebuild arm64 packages in QEMU arm64 chroot
#
# Creates a minimal noble arm64 chroot, installs build-deps,
# applies Rockchip patches, and builds .deb packages natively.
# This avoids cross-compilation issues (meson, libffi, etc).
# ==========================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHROOT="/tmp/rk-arm64-chroot"
OUTPUT="${SCRIPT_DIR}/ubuntu/rockchip-debs"
PATCHES="${SCRIPT_DIR}/patches/userland"
PKG="${1:-libdrm}"  # Package to rebuild (or "all")

echo "=== Rebuilding $PKG for arm64 in QEMU chroot ==="

# Step 1: Create minimal arm64 chroot if not exists
if [[ ! -d "$CHROOT/usr/bin" ]]; then
    echo "Creating noble arm64 chroot..."
    sudo rm -rf "$CHROOT"
    sudo debootstrap --arch arm64 noble "$CHROOT" https://mirrors.ustc.edu.cn/ubuntu-ports/ 2>&1 | tail -5
    sudo cp /usr/bin/qemu-aarch64-static "$CHROOT/usr/bin/"
fi

# Step 2: Install build tools inside chroot
sudo chroot "$CHROOT" bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential dpkg-dev devscripts ubuntu-dev-tools fakeroot 2>&1 | tail -3
'

# Step 3: Build package
rebuild() {
    local pkg="$1"
    local patch_dir="$PATCHES/$pkg"
    echo "=== Rebuilding $pkg ==="

    # Copy patches and build script into chroot
    sudo mkdir -p "$CHROOT/build"
    if [[ -d "$patch_dir" ]]; then
        sudo rm -rf "$CHROOT/build/patches"
        sudo cp -r "$patch_dir" "$CHROOT/build/patches"
    fi

    sudo chroot "$CHROOT" bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    cd /build
    rm -rf /build/src

    # Get source
    echo 'Getting source for $pkg...'
    pull-lp-source $pkg noble 2>&1 | tail -2
    srcdir=\$(find /build -maxdepth 1 -type d -name '${pkg}-*' | head -1)
    if [[ -z \"\$srcdir\" ]]; then
        echo 'ERROR: source not found'
        exit 1
    fi
    cd \"\$srcdir\"
    echo \"Source: \$(pwd)\"

    # Apply patches
    if [[ -d /build/patches ]]; then
        applied=0; failed=0
        for pf in \$(find /build/patches -name '*.patch' -type f | sort); do
            if patch -p1 -N --dry-run < \"\$pf\" 2>/dev/null; then
                patch -p1 < \"\$pf\" 2>/dev/null
                applied=\$((applied + 1))
            else
                echo \"  FAILED: \$(basename \$pf)\"
                failed=\$((failed + 1))
            fi
        done
        echo \"Patches: \$applied applied, \$failed failed\"
    fi

    # Install build deps
    apt-get build-dep -y -qq $pkg 2>&1 | tail -2

    # Build (native arm64, no cross-compilation issues)
    echo 'Building...'
    dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -10
    "

    # Copy debs out
    sudo find "$CHROOT/build" -maxdepth 1 -name "*.deb" -exec cp -v {} "$OUTPUT/" \;
    echo "$pkg done"
}

if [[ "$PKG" == "all" ]]; then
    for pkg in libdrm wayland weston xserver; do
        rebuild "$pkg" || true
    done
else
    rebuild "$PKG"
fi

echo "=== Output: $OUTPUT ==="
ls -lh "$OUTPUT/"
