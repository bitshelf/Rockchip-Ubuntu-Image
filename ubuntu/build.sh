#!/bin/bash
set -euo pipefail

# ==========================================================================
# build.sh — Ubuntu Image Build Orchestrator (multi-board)
#
# Usage:  BOARD=rk3588-board ./build.sh
#         BOARD=rk3576 UBUNTU_SERIES=questing ./build.sh
#
# Prerequisites:
#   - ubuntu-image snap (v3.x) or built from Go source
#   - qemu-user-static + binfmt-support for arm64 cross-build
#   - sgdisk (gdisk package)
#   - SDK at SDK_PATH with built kernel, U-Boot, and packages
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"

# Board selection (default: rk3576)
BOARD="${BOARD:-rk3576}"
BOARD_CONF="${PROJECT_DIR}/boards/${BOARD}.conf"

if [[ ! -f "${BOARD_CONF}" ]]; then
    echo "ERROR: Board config not found: ${BOARD_CONF}"
    echo "Available boards:"
    ls "${PROJECT_DIR}/boards/"*.conf 2>/dev/null | sed 's/.*\///;s/\.conf//' | sed 's/^/  /'
    exit 1
fi
source "${BOARD_CONF}"

# Ubuntu series (default from board config)
UBUNTU_SERIES="${UBUNTU_SERIES:-${UBUNTU_SERIES_DEFAULT}}"

# Sources resolved via board config URIs (file://, https://, git://)
# Mirror: auto-detect local apt-cacher-ng cache for faster builds
RESOLVE_MIRROR="${PROJECT_DIR}/scripts/resolve-mirror.sh"
APT_MIRROR="${UBUNTU_MIRROR}"
if [[ -x "${RESOLVE_MIRROR}" ]]; then
    APT_MIRROR=$("${RESOLVE_MIRROR}")
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -------------------------------------------------------------------
# Yocto-style source resolution
# Supports: file://path | https://url | git://url
# -------------------------------------------------------------------
SRC_CACHE="${HOME}/.cache/ubuntu-image-sources"

resolve_source() {
    local uri="$1"
    local name="$2"
    local srcrev="${3:-}"

    if [[ "${uri}" =~ ^file:// ]]; then
        # Local path
        local path="${uri#file://}"
        if [[ ! -d "${path}" ]]; then
            error "Local source not found: ${path}"
        fi
        echo "${path}"
        return
    fi

    # Remote: clone to cache
    mkdir -p "${SRC_CACHE}"
    local cached="${SRC_CACHE}/${name}"

    if [[ -d "${cached}/.git" ]]; then
        info "Updating cached source: ${name}"
        (cd "${cached}" && git fetch --depth 1 origin "${srcrev}" 2>/dev/null) || true
    else
        info "Cloning source: ${uri} -> ${cached}"
        git clone --depth 1 ${srcrev:+--branch "${srcrev}"} "${uri}" "${cached}"
    fi
    echo "${cached}"
}

# -------------------------------------------------------------------
# Check prerequisites
# -------------------------------------------------------------------
check_prereqs() {
    info "Checking prerequisites..."

    command -v /snap/bin/ubuntu-image >/dev/null 2>&1 || \
        error "ubuntu-image not found. Install: sudo snap install ubuntu-image --classic"

    command -v sgdisk >/dev/null 2>&1 || \
        error "sgdisk not found. Install: sudo apt-get install gdisk"

    command -v mkfs.ext4 >/dev/null 2>&1 || \
        error "mkfs.ext4 not found. Install: sudo apt-get install e2fsprogs"

    # Check qemu-user-static for arm64
    if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        warn "qemu-aarch64 binfmt not registered. Installing..."
        sudo apt-get install -y qemu-user-static binfmt-support
        sudo systemctl restart systemd-binfmt
    fi

    info "All prerequisites satisfied."
}

# -------------------------------------------------------------------
# Copy boot assets from SDK
# -------------------------------------------------------------------
copy_boot_assets() {
    info "Copying boot assets..."

    # Resolve source paths (local or remote via Yocto-style URIs)
    local uboot_src
    uboot_src=$(resolve_source "${UBOOT_URI}" "uboot-${BOARD}" "${UBOOT_SRCREV}")
    local kernel_src
    kernel_src=$(resolve_source "${KERNEL_URI}" "kernel-${BOARD}" "${KERNEL_SRCREV}")
    local boot_assets="${SCRIPT_DIR}/boot-assets"

    # idbloader (SPL + DDR init)
    if [[ -f "${uboot_src}/${IDBLOADER_SOURCE}" ]]; then
        cp -v "${uboot_src}/${IDBLOADER_SOURCE}" "${boot_assets}/idbloader.img"
    else
        warn "idbloader (${IDBLOADER_SOURCE}) not found in ${uboot_src}"
    fi

    # u-boot.itb
    if [[ -f "${uboot_src}/${UBOOT_SOURCE}" ]]; then
        cp -v "${uboot_src}/${UBOOT_SOURCE}" "${boot_assets}/u-boot.itb"
    else
        warn "u-boot (${UBOOT_SOURCE}) not found in ${uboot_src}"
    fi

    # boot.img (kernel FIT image)
    if [[ -f "${kernel_src}/boot.img" ]]; then
        cp -v "${kernel_src}/boot.img" "${boot_assets}/boot.img"
    elif [[ -f "${kernel_src}/arch/arm64/boot/Image" ]]; then
        cp -v "${kernel_src}/arch/arm64/boot/Image" "${boot_assets}/"
    else
        warn "boot.img not found in ${kernel_src}"
    fi

    # Device tree
    local dtb_path="${kernel_src}/${OVERLAY_SOURCE_DIR}/${DTB_BASE}"
    if [[ -f "${dtb_path}" ]]; then
        cp -v "${dtb_path}" "${boot_assets}/"
    else
        warn "${DTB_BASE} not found at ${dtb_path}"
    fi

    # DTS overlays
    local overlay_dir="${sdk_kernel}/arch/arm64/boot/dts/rockchip"
    if ls "${overlay_dir}/"*.dtbo 1>/dev/null 2>&1; then
        cp -v "${overlay_dir}/"*.dtbo "${boot_assets}/overlays/"
    fi

    info "Boot assets copied."
}

# -------------------------------------------------------------------
# Copy Rockchip debs from SDK
# -------------------------------------------------------------------
copy_rockchip_debs() {
    info "Copying Rockchip .deb packages from SDK..."

    local sdk_debs="${SDK_PATH}/debian/packages/arm64"
    local rockchip_debs="${SCRIPT_DIR}/rockchip-debs"

    if [[ ! -d "${sdk_debs}" ]]; then
        warn "SDK packages directory not found at ${sdk_debs}"
        return
    fi

    # Copy Rockchip-specific debs
    for pkg_dir in mpp rga2 libmali gst-rkmpp camera_engine_rkaiq rknpu2 rkwifibt rktoolkit libdrm-cursor; do
        if [[ -d "${sdk_debs}/${pkg_dir}" ]]; then
            mkdir -p "${rockchip_debs}/${pkg_dir}"
            cp -v "${sdk_debs}/${pkg_dir}/"*.deb "${rockchip_debs}/${pkg_dir}/" 2>/dev/null || true
        fi
    done

    info "Rockchip packages copied."
}

# -------------------------------------------------------------------
# Copy kernel debs from SDK
# -------------------------------------------------------------------
copy_kernel_debs() {
    info "Copying kernel .deb packages from SDK..."

    local sdk_parent="${SDK_PATH}/.."
    local kernel_debs="${SCRIPT_DIR}/kernel-debs"

    # Look for kernel debs built via make bindeb-pkg
    for pattern in "linux-image-6.1*.deb" "linux-headers-6.1*.deb" "linux-modules-6.1*.deb"; do
        find "${sdk_parent}" "${SDK_PATH}/kernel-6.1/.." "${SDK_PATH}" \
            -maxdepth 2 -name "${pattern}" -exec cp -v {} "${kernel_debs}/" \; 2>/dev/null || true
    done

    # Also look in the kernel source parent
    find "${SDK_PATH}/kernel-6.1/.." -maxdepth 1 -name "linux-image-*.deb" \
        -exec cp -v {} "${kernel_debs}/" \; 2>/dev/null || true

    if ls "${kernel_debs}/"*.deb 1>/dev/null 2>&1; then
        info "Kernel packages copied."
    else
        warn "No kernel .deb packages found. Build with: make bindeb-pkg in kernel-6.1/"
    fi
}

# -------------------------------------------------------------------
# Run ubuntu-image
# -------------------------------------------------------------------
run_ubuntu_image() {
    info "Running ubuntu-image classic to build rootfs tarball..."

    mkdir -p "${ARTIFACTS_DIR}"

    # Select YAML based on Ubuntu series
    local yaml_file="${SCRIPT_DIR}/image-definition.yaml"
    if [[ "${UBUNTU_SERIES}" == "questing" ]]; then
        yaml_file="${SCRIPT_DIR}/image-definition-questing.yaml"
    fi

    # Generate temporary YAML with resolved mirror
    local tmp_yaml="${ARTIFACTS_DIR}/image-definition-resolved.yaml"
    sed "s|mirror:.*|mirror: \"${APT_MIRROR}\"|" "${yaml_file}" > "${tmp_yaml}"
    info "Mirror: ${APT_MIRROR}"

    sudo /snap/bin/ubuntu-image classic \
        --image-definition "${tmp_yaml}" \
        --output-dir "${ARTIFACTS_DIR}" \
        -d 2>&1 | tee "${ARTIFACTS_DIR}/ubuntu-image.log"

    if [[ -f "${ARTIFACTS_DIR}/rootfs.tar.gz" ]]; then
        info "Rootfs tarball created: ${ARTIFACTS_DIR}/rootfs.tar.gz"
    else
        error "ubuntu-image rootfs tarball not found! Check ${ARTIFACTS_DIR}/ubuntu-image.log"
    fi
}

# -------------------------------------------------------------------
# Verify image
# -------------------------------------------------------------------
verify_image() {
    info "Verifying image..."

    local img="${ARTIFACTS_DIR}/ubuntu-24.04-preinstalled-server-arm64+myd-lr3576.img"

    # Partition table
    info "Partition layout:"
    sgdisk -p "${img}"

    # Bootloader check
    echo ""
    info "Bootloader at LBA 64:"
    dd if="${img}" bs=512 skip=64 count=4 2>/dev/null | hexdump -C | head -4

    echo ""
    info "Bootloader at LBA 16384:"
    dd if="${img}" bs=512 skip=16384 count=4 2>/dev/null | hexdump -C | head -4

    # Mount and check OS (p2 = rootfs, p3 = overlay)
    echo ""
    info "Verifying rootfs contents..."
    local loopdev
    loopdev=$(sudo losetup --show -fP "${img}")
    local mnt
    mnt=$(mktemp -d)
    sudo mount "${loopdev}p2" "${mnt}"

    # Check overlay partition
    local overlay_mnt
    overlay_mnt=$(mktemp -d)
    sudo mount "${loopdev}p3" "${overlay_mnt}"
    if [[ -d "${overlay_mnt}/upper" && -d "${overlay_mnt}/work" ]]; then
        info "  Overlay partition with upper/ and work/ dirs (OK)"
    fi
    sudo umount "${overlay_mnt}" 2>/dev/null || true
    rmdir "${overlay_mnt}"

    if [[ -f "${mnt}/etc/os-release" ]]; then
        info "OS release:"
        grep PRETTY_NAME "${mnt}/etc/os-release" || true
    fi

    # Check for excluded packages
    info "Checking for excluded packages..."
    local found_games
    found_games=$(sudo chroot "${mnt}" dpkg -l 2>/dev/null | grep -iE 'gnome-games|gnome-sudoku|gnome-mines|gnome-mahjongg|aisleriot' || true)
    if [[ -z "${found_games}" ]]; then
        info "  No games packages found (OK)"
    else
        warn "  Games packages detected!"
    fi

    local found_updates
    found_updates=$(sudo chroot "${mnt}" dpkg -l 2>/dev/null | grep -iE 'unattended-upgrades|update-notifier|update-manager-core' || true)
    if [[ -z "${found_updates}" ]]; then
        info "  No background update services found (OK)"
    else
        warn "  Background update services detected!"
    fi

    # Check boot assets
    info "Boot assets:"
    ls -lh "${mnt}/boot/" 2>/dev/null || warn "  /boot empty"

    # Check DTS overlays
    if ls "${mnt}/boot/overlays/"*.dtbo 2>/dev/null; then
        info "  DTS overlays present (OK)"
    fi

    # Check overlay initramfs hook
    info "Checking overlay initramfs hook..."
    if [[ -x "${mnt}/etc/initramfs-tools/scripts/init-bottom/overlay" ]]; then
        info "  initramfs overlay hook installed (OK)"
    else
        warn "  initramfs overlay hook missing!"
    fi

    # Check disabled timers
    info "Checking disabled timers..."
    if sudo chroot "${mnt}" systemctl is-enabled apt-daily.timer 2>&1 | grep -q 'disabled\|masked'; then
        info "  apt-daily.timer disabled (OK)"
    fi

    sudo umount "${mnt}"
    sudo losetup -d "${loopdev}"
    rmdir "${mnt}"

    # Generate SHA256
    info "Generating SHA256SUMS..."
    (cd "${ARTIFACTS_DIR}" && sha256sum "${img##*/}" > SHA256SUMS)

    # Compress
    info "Compressing image..."
    xz -3 -f -T0 "${img}"
    info "Compressed: ${img}.xz"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    echo ""
    echo "============================================="
    echo " RK3576 Ubuntu 24.04 Image Builder"
    echo "============================================="
    echo ""

    check_prereqs
    copy_boot_assets
    copy_rockchip_debs
    copy_kernel_debs
    run_ubuntu_image

    info "Assembling final disk image..."
    sudo bash "${SCRIPT_DIR}/assemble-disk.sh"

    verify_image

    echo ""
    info "Build complete!"
    info "Image: ${ARTIFACTS_DIR}/ubuntu-24.04-preinstalled-server-arm64+myd-lr3576.img.xz"
}

main "$@"
