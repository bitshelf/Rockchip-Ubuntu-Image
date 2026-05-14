#!/bin/bash
# ==========================================================================
# rebuild-rockchip-packages.sh — Apply Rockchip SDK patches to Ubuntu pkgs
#
# Workflow per package:
#   1. Get Ubuntu source: apt-get source <package>
#   2. Apply Rockchip patches from SDK
#   3. Build .deb: dpkg-buildpackage
#   4. Copy .deb to ubuntu/rockchip-debs/
#
# Package build order (dependency-aware):
#   Critical: libdrm, wayland
#   High:     weston, xserver, gstreamer1
#   Medium:   v4l-utils
#   Low:      blueman, cheese, wireplumber, openbox, pcmanfm
#   Complex:  chromium (50+ patches, manual review needed)
# ==========================================================================
set -euo pipefail

PATCHES_DIR="$(cd "$(dirname "$0")/.." && pwd)/packages-patches/userland"
OUTPUT_DEBS="${OUTPUT_DEBS:-$(cd "$(dirname "$0")/.." && pwd)/ubuntu/rockchip-debs}"
WORK_DIR="${WORK_DIR:-/tmp/rockchip-rebuild}"
UBUNTU_SERIES="${UBUNTU_SERIES:-noble}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

mkdir -p "$OUTPUT_DEBS" "$WORK_DIR"

rebuild_package() {
    local name="$1"        # Package name (e.g. libdrm, weston)
    local patch_dir="$2"   # Subdirectory in packages-patches
    local ubuntu_pkg="$3"  # Ubuntu package name (may differ for gstreamer)

    info "=== Rebuilding: $name ==="

    local build_dir="${WORK_DIR}/${name}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Step 1: Get Ubuntu source
    info "  Getting Ubuntu source for $ubuntu_pkg..."
    if ! apt-get source "$ubuntu_pkg" 2>&1; then
        warn "  Failed to get source for $ubuntu_pkg, skipping"
        return 1
    fi

    # Find source directory
    local src_dir
    src_dir=$(find . -maxdepth 1 -type d -name "${ubuntu_pkg}-*" | head -1)
    if [[ -z "$src_dir" ]]; then
        src_dir=$(find . -maxdepth 1 -type d ! -name '.' | head -1)
    fi
    if [[ -z "$src_dir" ]]; then
        error "  Cannot find extracted source directory"
    fi
    info "  Source: $src_dir"

    # Step 2: Apply Rockchip patches
    local patches="${PATCHES_DIR}/${patch_dir}"
    if [[ ! -d "$patches" ]]; then
        warn "  No patches at $patches, skipping patch step"
    else
        cd "$src_dir"
        local patch_count=0
        # Find all patches (flat or in version subdirectory)
        for patch_file in $(find "$patches" -name "*.patch" -type f | sort); do
            info "    Applying: $(basename "$patch_file")"
            if patch -p1 -N --dry-run < "$patch_file" 2>/dev/null; then
                patch -p1 < "$patch_file"
                patch_count=$((patch_count + 1))
            elif patch -p0 -N --dry-run < "$patch_file" 2>/dev/null; then
                patch -p0 < "$patch_file"
                patch_count=$((patch_count + 1))
            else
                warn "    FAILED to apply $(basename "$patch_file") with -p1 or -p0"
            fi
        done
        info "  Applied $patch_count patches"
        cd "$build_dir"
    fi

    # Step 3: Build
    info "  Building..."
    cd "$src_dir"
    if dpkg-buildpackage -us -uc -b -j$(nproc) 2>&1 | tail -5; then
        info "  Build succeeded"
    else
        error "  Build failed for $name"
    fi
    cd "$build_dir"

    # Step 4: Copy .debs
    local deb_count=0
    for deb in *.deb; do
        [[ -f "$deb" ]] || continue
        cp -v "$deb" "$OUTPUT_DEBS/"
        deb_count=$((deb_count + 1))
    done
    info "  Copied $deb_count .deb packages to $OUTPUT_DEBS/"
}

# ==========================================================================
# Build Order (dependency-aware)
# ==========================================================================

info "Starting Rockchip package rebuild for Ubuntu $UBUNTU_SERIES"
info "Patches: $PATCHES_DIR"
info "Output:  $OUTPUT_DEBS"
echo ""

# --- Critical: Graphics infrastructure ---
for pkg in "libdrm libdrm libdrm" \
           "wayland wayland wayland"; do
    read -r name patch_dir ubuntu_pkg <<< "$pkg"
    rebuild_package "$name" "$patch_dir" "$ubuntu_pkg" || warn "Continuing without $name"
done

# --- High: Display servers ---
rebuild_package "weston" "weston/10.0.1" "weston" || true
rebuild_package "xserver" "xserver/21.1.7" "xorg-server" || true

# --- High: GStreamer media framework ---
rebuild_package "gstreamer1-core" "gstreamer1/gstreamer1" "gstreamer1.0" || true
rebuild_package "gst-plugins-base" "gstreamer1/gst1-plugins-base" "gst-plugins-base1.0" || true
rebuild_package "gst-plugins-good" "gstreamer1/gst1-plugins-good" "gst-plugins-good1.0" || true
rebuild_package "gst-plugins-bad" "gstreamer1/gst1-plugins-bad" "gst-plugins-bad1.0" || true

# --- Medium: Video/Image ---
rebuild_package "v4l-utils" "v4l-utils" "v4l-utils" || true

# --- Low: Desktop utilities ---
rebuild_package "blueman" "blueman" "blueman" || true
rebuild_package "cheese" "cheese" "cheese" || true
rebuild_package "wireplumber" "wireplumber" "wireplumber" || true
rebuild_package "openbox" "openbox" "openbox" || true
rebuild_package "pcmanfm" "pcmanfm" "pcmanfm" || true

echo ""
info "================================================"
info "Rebuild complete. Packages in: $OUTPUT_DEBS"
ls -lh "$OUTPUT_DEBS/" 2>/dev/null || warn "No packages built"
info "================================================"
