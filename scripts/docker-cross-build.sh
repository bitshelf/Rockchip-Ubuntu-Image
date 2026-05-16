#!/bin/bash
# ==========================================================================
# docker-cross-build.sh — Cross-build arm64 packages via Docker + QEMU
#
# Ubuntu official cross-compilation equivalent:
#   "sbuild --host=arm64 with QEMU chroot (Ubuntu official)"
#
# Docker --platform linux/arm64 achieves the same: QEMU-user binfmt_misc
# runs an arm64 container where packages build natively - no cross-compile.
#
# Usage: ./scripts/docker-cross-build.sh [pkg1 pkg2 ...]
#        ./scripts/docker-cross-build.sh              # build all
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${SCRIPT_DIR}/ubuntu/rockchip-debs"
PATCHES="${SCRIPT_DIR}/patches/userland"
IMAGE="arm64v8/ubuntu:noble"
UBUNTU_SERIES="${UBUNTU_SERIES:-noble}"

# Source package name mapping
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$OUTPUT"

# ==========================================================================
# Find the best patch directory (host-side, before docker build)
# Priority: noble/ > flat patches > version subdirectories
# ==========================================================================
find_patch_dir() {
    local pkg="$1"
    local base="${PATCHES}/${pkg}"

    [[ ! -d "$base" ]] && { echo ""; return; }

    # 1. noble/ subdirectory
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
    [[ -n "$sub" ]] && echo "$sub"
}

# ==========================================================================
# Build one package in Docker
# ==========================================================================
build_one() {
    local pkg="$1"
    local src="${SRC_MAP[$pkg]:-$pkg}"
    local patch_dir
    patch_dir=$(find_patch_dir "$pkg")

    echo ""
    info "========== $pkg (src: $src) =========="
    info "Patches: ${patch_dir:-none}"

    # Prepare build context in a temp dir
    local build_ctx
    build_ctx=$(mktemp -d /tmp/rk-docker-build-XXXXXX)
    trap "rm -rf $build_ctx" RETURN

    mkdir -p "$build_ctx/output" "$build_ctx/patches"

    # Copy patches into build context
    if [[ -n "$patch_dir" && -d "$patch_dir" ]]; then
        cp "$patch_dir"/*.patch "$build_ctx/patches/" 2>/dev/null || true
    fi

    # Write build script to run inside container
    cat > "$build_ctx/build.sh" << 'INNERSCRIPT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PKG="$1"
SRC="$2"
SERIES="$3"

echo "=== Installing build tools ==="
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq build-essential dpkg-dev devscripts ubuntu-dev-tools fakeroot 2>&1 | tail -2

cd /build
rm -rf /build/src /build/*.deb

# Get source
echo "=== Getting source for $SRC ($SERIES) ==="
pull-lp-source "$SRC" "$SERIES" 2>&1 | tail -3
srcdir=$(find /build -maxdepth 1 -type d -name "${SRC}-*" | head -1)
if [[ -z "$srcdir" ]]; then
    echo "ERROR: source directory not found"
    exit 1
fi
cd "$srcdir"
echo "Source: $(pwd)"

# Apply patches
if ls /build/patches/*.patch &>/dev/null 2>&1; then
    applied=0; failed=0
    for pf in $(ls /build/patches/*.patch | sort); do
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
    echo "No patches to apply"
fi

# Install build dependencies
echo "=== Installing build dependencies ==="
apt-get build-dep -y -qq "$SRC" 2>&1 | tail -5 || {
    echo "WARNING: build-dep failed, trying mk-build-deps"
    apt-get install -y -qq equivs 2>&1 | tail -1
    mk-build-deps --install --remove --tool 'apt-get -y -qq' debian/control 2>&1 | tail -5 || true
}

# Build
echo "=== Building $PKG for arm64 ==="
dpkg-buildpackage -us -uc -b -j$(nproc) 2>&1 | tail -30

# Copy debs to output
find /build -maxdepth 1 -name "*.deb" -type f -exec cp -v {} /output/ \;
echo "=== Done: $(find /build -maxdepth 1 -name '*.deb' | wc -l) debs built ==="
INNERSCRIPT

    chmod +x "$build_ctx/build.sh"

    # Run build in arm64 container
    local rc=0
    docker run --rm --platform linux/arm64 \
        -e QEMU_CPU=max \
        -v "$build_ctx/build.sh:/build.sh:ro" \
        -v "$build_ctx/patches:/build/patches:ro" \
        -v "$build_ctx/output:/output" \
        "$IMAGE" /build.sh "$pkg" "$src" "$UBUNTU_SERIES" 2>&1 || rc=$?

    # Copy debs to final output
    local deb_count
    deb_count=$(find "$build_ctx/output" -maxdepth 1 -name "*.deb" -type f | wc -l)
    if [[ "$deb_count" -gt 0 ]]; then
        cp -v "$build_ctx/output"/*.deb "$OUTPUT/"
        info "$pkg: $deb_count .deb(s) built successfully"
    else
        warn "$pkg: no .deb produced (exit code: $rc)"
        return 1
    fi
}

# ==========================================================================
# Main
# ==========================================================================
info "================================================"
info "Rockchip arm64 Cross-Build via Docker + QEMU"
info "  Method:  Ubuntu official (QEMU arm64 container → native build)"
info "  Image:   $IMAGE"
info "  Target:  arm64 ($UBUNTU_SERIES)"
info "  Output:  $OUTPUT"
info "================================================"

# Pull image once
info "Pulling $IMAGE..."
docker pull --platform linux/arm64 "$IMAGE" 2>&1 | tail -2

# Determine which packages to build
if [[ $# -gt 0 ]]; then
    PACKAGES=("$@")
else
    PACKAGES=("${BUILD_ORDER[@]}")
fi

info "Packages: ${PACKAGES[*]}"
echo ""

built=0; failed=0
for pkg in "${PACKAGES[@]}"; do
    if [[ -z "${SRC_MAP[$pkg]:-}" ]]; then
        warn "Unknown package: $pkg, skipping"
        continue
    fi
    if build_one "$pkg"; then
        built=$((built + 1))
    else
        failed=$((failed + 1))
    fi
done

echo ""
info "================================================"
info "Build complete: $built ok, $failed failed"
info "Output: $OUTPUT"
ls -lh "$OUTPUT/" 2>/dev/null || warn "No packages in output"
info "================================================"
exit $failed
