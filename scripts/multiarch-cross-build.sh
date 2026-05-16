#!/bin/bash
# ==========================================================================
# multiarch-cross-build.sh — Cross-compile arm64 packages via multiarch
#
# Ubuntu official method: dpkg-buildpackage -aarm64 (multiarch cross)
# Per .rules: "Fallback: dpkg-buildpackage -aarm64 -d for simple packages"
#
# Proven to work for libdrm. Key ingredients:
#   1. Multiarch: amd64 (build) + arm64 (host)
#   2. crossbuild-essential-arm64 (compiler, linker)
#   3. aarch64-linux-gnu-pkg-config wrapper (arm64 .pc file discovery)
#   4. arm64 dev packages for link-time libraries
#   5. amd64 build tools for compile-time tools (docutils, etc.)
#
# Usage: ./scripts/multiarch-cross-build.sh [pkg1 pkg2 ...]
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/ubuntu/rockchip-debs}"
PATCHES="${SCRIPT_DIR}/patches/userland"
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

# Arm64 dev packages needed by each source package (cumulative from earlier builds)
# These get installed in the Docker container to satisfy pkg-config lookups
declare -A ARM64_DEPS=(
    [libdrm]="libpciaccess-dev:arm64 libudev-dev:arm64"
    [wayland]="libffi-dev:arm64 libexpat1-dev:arm64 libxml2-dev:arm64"
    [weston]="libdrm-dev:arm64 libwayland-dev:arm64 libpixman-1-dev:arm64 libcairo2-dev:arm64 libinput-dev:arm64 libgbm-dev:arm64 libgles2-mesa-dev:arm64 libegl1-mesa-dev:arm64 libxkbcommon-dev:arm64"
    [xserver]="libdrm-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 libxdamage-dev:arm64 libxfixes-dev:arm64 libxfont-dev:arm64 libxkbfile-dev:arm64 libpciaccess-dev:arm64 libudev-dev:arm64 libepoxy-dev:arm64"
    [v4l-utils]="libudev-dev:arm64"
    [mpv]="libwayland-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 libv4l-dev:arm64"
    [blueman]="libglib2.0-dev:arm64 libbluetooth-dev:arm64"
    [cheese]="libglib2.0-dev:arm64 libgtk-3-dev:arm64"
    [openbox]="libglib2.0-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 libpango1.0-dev:arm64"
    [pcmanfm]="libglib2.0-dev:arm64 libgtk-3-dev:arm64 libfm-dev:arm64"
    [wireplumber]="libglib2.0-dev:arm64 libpipewire-0.3-dev:arm64"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$OUTPUT"

# ==========================================================================
# Find the best patch directory
# ==========================================================================
find_patch_dir() {
    local pkg="$1"
    local base="${PATCHES}/${pkg}"
    [[ ! -d "$base" ]] && { echo ""; return; }
    if [[ -d "$base/noble" ]] && ls "$base/noble/"*.patch &>/dev/null 2>&1; then
        echo "$base/noble"; return
    fi
    if ls "$base/"*.patch &>/dev/null 2>&1; then
        echo "$base"; return
    fi
    local sub
    sub=$(find "$base" -mindepth 2 -maxdepth 2 -name "*.patch" -type f -print -quit 2>/dev/null | xargs dirname 2>/dev/null)
    [[ -n "$sub" ]] && echo "$sub"
}

# ==========================================================================
# Write the in-Docker build script (self-contained)
# ==========================================================================
write_build_script() {
    local build_dir="$1"
    cat > "$build_dir/build-in-docker.sh" << 'INNER_SCRIPT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PKG="$1"
SRC="$2"
SERIES="${3:-noble}"

echo "=== Building $PKG (src: $SRC) for arm64 ==="

# Setup apt (once)
rm -f /etc/apt/sources.list.d/ubuntu.sources
dpkg --add-architecture arm64 2>/dev/null || true
cat > /etc/apt/sources.list << 'APTEOF'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ noble main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ noble-updates main restricted universe multiverse
APTEOF
apt-get update -qq 2>&1 | tail -1

# Install base tools (idempotent)
apt-get install -y -qq \
    build-essential dpkg-dev devscripts ubuntu-dev-tools \
    crossbuild-essential-arm64 debhelper quilt fakeroot equivs \
    meson ninja-build pkgconf cmake python3-docutils \
    2>&1 | tail -1

# Cross pkg-config wrapper (idempotent)
cat > /usr/bin/aarch64-linux-gnu-pkg-config << 'PKGWRAP'
#!/bin/sh
export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
exec /usr/bin/pkg-config "$@"
PKGWRAP
chmod +x /usr/bin/aarch64-linux-gnu-pkg-config

# Get source
cd /tmp
rm -rf /tmp/build-*
pull-lp-source "$SRC" "$SERIES" 2>&1 | tail -2
srcdir=$(find /tmp -maxdepth 1 -type d -name "${SRC}-*" | head -1)
[[ -z "$srcdir" ]] && { echo "ERROR: source not found"; exit 1; }
cd "$srcdir"
echo "Source: $(pwd)"

# Apply patches
if ls /patches/*.patch &>/dev/null 2>&1; then
    applied=0; failed=0
    for pf in $(ls /patches/*.patch | sort); do
        if patch -p1 -N --dry-run < "$pf" 2>/dev/null; then
            patch -p1 < "$pf" 2>/dev/null
            applied=$((applied + 1))
            echo "  OK: $(basename $pf)"
        else
            echo "  FAIL: $(basename $pf)"
            failed=$((failed + 1))
        fi
    done
    echo "Patches: $applied/$((applied+failed)) applied"
fi

# Install arm64 dev packages from the deps list
if [[ -f /arm64-deps.txt ]] && grep -q '[^[:space:]]' /arm64-deps.txt 2>/dev/null; then
    echo "=== Installing arm64 dev libraries ==="
    # shellcheck disable=SC2046
    apt-get install -y -qq $(cat /arm64-deps.txt) 2>&1 | tail -3 || {
        echo "Some arm64 packages failed, continuing anyway"
    }
fi

# Install build deps for the host (amd64) - needed for build tools
echo "=== Installing build dependencies ==="
apt-get build-dep -y -qq "$SRC" 2>&1 | tail -3 || {
    echo "build-dep not fully satisfied, using -d flag"
}

# Cross-build
echo "=== Cross-building $PKG (-aarm64) ==="
dpkg-buildpackage -aarm64 -d -us -uc -b -j"$(nproc)" 2>&1 | tail -25

# Collect debs
find /tmp -maxdepth 1 -name "*.deb" -type f -exec cp -v {} /output/ \; 2>/dev/null || true
echo "=== $PKG: $(find /tmp -maxdepth 1 -name "*.deb" -type f | wc -l) debs ==="
INNER_SCRIPT
    chmod +x "$build_dir/build-in-docker.sh"
}

# ==========================================================================
# Build one package
# ==========================================================================
build_one() {
    local pkg="$1"
    local src="${SRC_MAP[$pkg]:-$pkg}"
    local patch_dir
    patch_dir=$(find_patch_dir "$pkg")
    local arm64_deps="${ARM64_DEPS[$pkg]:-}"

    echo ""
    info "========== $pkg (src: $src) =========="
    info "Patches: ${patch_dir:-none}"
    info "Arm64 deps: ${arm64_deps:-none}"

    local build_ctx
    build_ctx=$(mktemp -d /tmp/rk-cross-XXXXXX)
    trap "rm -rf $build_ctx" RETURN

    mkdir -p "$build_ctx/output" "$build_ctx/patches"

    # Copy patches
    if [[ -n "$patch_dir" && -d "$patch_dir" ]]; then
        cp "$patch_dir"/*.patch "$build_ctx/patches/" 2>/dev/null || true
    fi

    # Write arm64 deps file
    echo "$arm64_deps" > "$build_ctx/arm64-deps.txt"

    # Write build script
    write_build_script "$build_ctx"

    # Run in amd64 noble container (native speed!)
    local rc=0
    docker run --rm --platform linux/amd64 \
        -v "$build_ctx/build-in-docker.sh:/build.sh:ro" \
        -v "$build_ctx/patches:/patches:ro" \
        -v "$build_ctx/arm64-deps.txt:/arm64-deps.txt:ro" \
        -v "$build_ctx/output:/output" \
        ubuntu:noble /build.sh "$pkg" "$src" "$UBUNTU_SERIES" 2>&1 || rc=$?

    # Copy debs to final output
    local deb_count
    deb_count=$(find "$build_ctx/output" -maxdepth 1 -name "*.deb" -type f | wc -l)
    if [[ "$deb_count" -gt 0 ]]; then
        cp -v "$build_ctx/output"/*.deb "$OUTPUT/"
        info "$pkg: $deb_count .deb(s) OK"
    else
        warn "$pkg: FAILED (rc=$rc)"
        return 1
    fi
}

# ==========================================================================
# Main
# ==========================================================================
info "================================================"
info "Rockchip arm64 Cross-Build (Multiarch Method)"
info "  Method: dpkg-buildpackage -aarm64 (multiarch)"
info "  Target: arm64 ($UBUNTU_SERIES)"
info "  Output: $OUTPUT"
info "================================================"

if [[ $# -gt 0 ]]; then
    PACKAGES=("$@")
else
    PACKAGES=("${BUILD_ORDER[@]}")
fi

info "Packages: ${PACKAGES[*]}"

# Pull base image
docker pull --platform linux/amd64 ubuntu:noble 2>&1 | tail -1

built=0; failed=0
for pkg in "${PACKAGES[@]}"; do
    if [[ -z "${SRC_MAP[$pkg]:-}" ]]; then
        warn "Unknown: $pkg"
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
info "Complete: $built ok, $failed failed"
info "Output: $OUTPUT"
ls -lh "$OUTPUT/" 2>/dev/null
info "================================================"
exit $failed
