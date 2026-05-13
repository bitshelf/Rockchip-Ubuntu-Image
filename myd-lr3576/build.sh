#!/bin/bash
set -euo pipefail

# ==========================================================================
# build.sh — MYiR MYD-LR3576 Ubuntu 24.04 Image Build Orchestrator
#
# Prerequisites:
#   - ubuntu-image snap (v3.x): sudo snap install ubuntu-image --classic
#   - qemu-user-static + binfmt-support for arm64 cross-build
#   - sgdisk (gdisk package)
#   - RK3576 SDK at SDK_PATH with built kernel, U-Boot, and Rockchip packages
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"

# SDK location (configurable via environment)
SDK_PATH="${SDK_PATH:-/media/loh/rockchip/lr3576_v2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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
    info "Copying boot assets from SDK..."

    local sdk_uboot="${SDK_PATH}/u-boot"
    local sdk_kernel="${SDK_PATH}/kernel-6.1"
    local sdk_output="${SDK_PATH}/output/firmware"
    local boot_assets="${SCRIPT_DIR}/boot-assets"

    # idbloader (SPL + DDR init)
    if [[ -f "${sdk_uboot}/rk3576_spl_loader_v1.09.108.bin" ]]; then
        cp -v "${sdk_uboot}/rk3576_spl_loader_v1.09.108.bin" "${boot_assets}/idbloader.img"
    elif [[ -f "${sdk_output}/MiniLoaderAll.bin" ]]; then
        cp -v "${sdk_output}/MiniLoaderAll.bin" "${boot_assets}/idbloader.img"
    else
        warn "idbloader not found in SDK, build U-Boot first"
    fi

    # u-boot.itb
    if [[ -f "${sdk_uboot}/uboot.img" ]]; then
        cp -v "${sdk_uboot}/uboot.img" "${boot_assets}/u-boot.itb"
    elif [[ -f "${sdk_output}/uboot.img" ]]; then
        cp -v "${sdk_output}/uboot.img" "${boot_assets}/u-boot.itb"
    else
        warn "uboot.img not found in SDK, build U-Boot first"
    fi

    # boot.img (kernel FIT image)
    if [[ -f "${sdk_output}/boot.img" ]]; then
        cp -v "${sdk_output}/boot.img" "${boot_assets}/boot.img"
    elif [[ -f "${sdk_kernel}/boot.img" ]]; then
        cp -v "${sdk_kernel}/boot.img" "${boot_assets}/boot.img"
    else
        warn "boot.img not found in SDK, build kernel first"
    fi

    # Device tree
    local dtb_path="${sdk_kernel}/arch/arm64/boot/dts/rockchip/myd-lr3576.dtb"
    if [[ -f "${dtb_path}" ]]; then
        cp -v "${dtb_path}" "${boot_assets}/myd-lr3576.dtb"
    else
        warn "myd-lr3576.dtb not found in SDK"
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

    sudo /snap/bin/ubuntu-image classic \
        --image-definition "${SCRIPT_DIR}/image-definition.yaml" \
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

    # Mount and check OS
    echo ""
    info "Verifying rootfs contents..."
    local loopdev
    loopdev=$(sudo losetup --show -fP "${img}")
    local mnt
    mnt=$(mktemp -d)
    sudo mount "${loopdev}p2" "${mnt}"

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
    echo " MYD-LR3576 Ubuntu 24.04 Image Builder"
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
