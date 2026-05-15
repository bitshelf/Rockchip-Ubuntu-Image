#!/bin/bash
set -euo pipefail
# ==========================================================================
# Rebuild all Rockchip-patched packages for arm64 using Docker + QEMU chroot
# This avoids cross-compilation issues by building NATIVELY inside chroot.
# ==========================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${SCRIPT_DIR}/ubuntu/rockchip-debs"
PATCHES="${SCRIPT_DIR}/patches/userland"
CHROOT="/tmp/rk-pkg-chroot"

mkdir -p "$OUTPUT"

# Step 1: Create noble arm64 chroot via debootstrap
echo "=== Creating noble arm64 chroot ==="
sudo rm -rf "$CHROOT"
sudo debootstrap --arch arm64 noble "$CHROOT" https://mirrors.ustc.edu.cn/ubuntu-ports/ 2>&1 | tail -3
sudo cp /usr/bin/qemu-aarch64-static "$CHROOT/usr/bin/"

# Step 2: Install build tools
sudo chroot "$CHROOT" bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential dpkg-dev devscripts ubuntu-dev-tools fakeroot 2>&1 | tail -2
'

# Step 3: Rebuild function
rebuild() { local pkg="$1" name="${2:-$1}"
    echo "=== $pkg ==="
    local patch_dir="${PATCHES}/${name}"
    sudo mkdir -p "$CHROOT/build/src"
    [[ -d "$patch_dir" ]] && sudo cp -r "$patch_dir" "$CHROOT/build/patches" || sudo rm -rf "$CHROOT/build/patches"

    sudo chroot "$CHROOT" bash -c "
    set -euo pipefail; export DEBIAN_FRONTEND=noninteractive
    cd /build
    pull-lp-source $pkg noble 2>&1 | tail -2
    srcdir=\$(ls -d /build/${pkg}-* 2>/dev/null | head -1)
    [[ -z \"\$srcdir\" ]] && { echo 'FAIL: no source'; exit 1; }
    cd \"\$srcdir\"

    # Apply patches
    applied=0; failed=0
    if [[ -d /build/patches ]]; then
        for pf in \$(find /build/patches -name '*.patch' | sort); do
            patch -p1 -N < \"\$pf\" 2>/dev/null && applied=\$((applied+1)) || { echo \"  FAIL: \$(basename \$pf)\"; failed=\$((failed+1)); }
        done
    fi
    echo \"Patches: \$applied/\$((applied+failed))\"

    # Build deps + build
    apt-get build-dep -y -qq $pkg 2>&1 | tail -1
    dpkg-buildpackage -us -uc -b -j\$(nproc) 2>&1 | tail -5
    "
    sudo find "$CHROOT/build" -maxdepth 1 -name "*.deb" -exec cp {} "$OUTPUT/" \;
    echo "$pkg: $(sudo find "$CHROOT/build" -maxdepth 1 -name '*.deb' | wc -l) debs"
}

echo "=== Rebuilding packages ==="
for pkg in libdrm wayland; do rebuild "$pkg"; done

echo "=== Done ===" && ls -lh "$OUTPUT/"
