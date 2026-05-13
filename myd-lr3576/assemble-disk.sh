#!/bin/bash
set -euo pipefail

# ==========================================================================
# assemble-disk.sh — Assemble final RK3576 disk image
#
# Takes the ubuntu-image rootfs tarball and combines it with Rockchip
# bootloader binaries (idbloader, u-boot.itb) and kernel FIT image (boot.img)
# to produce a bootable SD card / eMMC image.
#
# Bootloader placement:
#   - idbloader at LBA 64 (raw, outside any partition)
#   - u-boot.itb at LBA 16384 (raw, outside any partition)
#   - GPT partitions start at LBA 32768
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
BOOT_ASSETS="${SCRIPT_DIR}/boot-assets"
OVERLAY="${SCRIPT_DIR}/ubuntu-overlay"
ROCKCHIP_DEBS="${SCRIPT_DIR}/rockchip-debs"
KERNEL_DEBS="${SCRIPT_DIR}/kernel-debs"

DISK_IMG="${ARTIFACTS_DIR}/ubuntu-24.04-preinstalled-server-arm64+myd-lr3576.img"
DISK_SIZE_MB=8192  # 8 GB for SD card
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"

IDBLOADER="${BOOT_ASSETS}/idbloader.img"
UBOOT="${BOOT_ASSETS}/u-boot.itb"
BOOT_IMG="${BOOT_ASSETS}/boot.img"

# -------------------------------------------------------------------
# Step 1: Create sparse disk image
# -------------------------------------------------------------------
echo "==> Creating sparse disk image (${DISK_SIZE_MB}MB)..."
truncate -s "${DISK_SIZE_MB}M" "${DISK_IMG}"

# -------------------------------------------------------------------
# Step 2: Create GPT partition table
# Partitions start at LBA 32768 to leave room for:
#   LBA 0-33: GPT headers
#   LBA 64: idbloader (SPL + DDR init)
#   LBA 16384: u-boot.itb
# -------------------------------------------------------------------
echo "==> Creating GPT partition table..."
sgdisk --clear "${DISK_IMG}"

# Partition 1: boot (ext4) at LBA 32768, 256 MB
sgdisk --new=1:32768:+256M \
  --typecode=1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --change-name=1:boot "${DISK_IMG}"

# Partition 2: rootfs (ext4), remaining minus userdata/oem
sgdisk --new=2:0:+6144M \
  --typecode=2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=2:rootfs "${DISK_IMG}"

# Partition 3: oem (ext4), 16 MB
sgdisk --new=3:0:+16M \
  --typecode=3:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=3:oem "${DISK_IMG}"

# Partition 4: userdata (ext4), remaining space
sgdisk --new=4:0:0 \
  --typecode=4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=4:userdata "${DISK_IMG}"

# -------------------------------------------------------------------
# Step 3: Write bootloader binaries at raw offsets
# -------------------------------------------------------------------
echo "==> Writing bootloader binaries..."

if [[ ! -f "${IDBLOADER}" ]]; then
    echo "ERROR: idbloader.img not found at ${IDBLOADER}"
    exit 1
fi
if [[ ! -f "${UBOOT}" ]]; then
    echo "ERROR: u-boot.itb not found at ${UBOOT}"
    exit 1
fi

# idbloader at LBA 64 (64 * 512 = 32768 byte offset)
echo "  idbloader at LBA 64..."
dd if="${IDBLOADER}" of="${DISK_IMG}" bs=512 seek=64 conv=notrunc,fsync status=none
echo "  OK"

# u-boot.itb at LBA 16384 (16384 * 512 = 8388608 byte offset)
UBOOT_SIZE=$(stat -Lc "%s" "${UBOOT}")
UBOOT_SECTORS=$(( (UBOOT_SIZE + 511) / 512 ))
echo "  u-boot.itb at LBA 16384 (${UBOOT_SECTORS} sectors)..."
dd if="${UBOOT}" of="${DISK_IMG}" bs=512 seek=16384 conv=notrunc,fsync status=none
echo "  OK"

# Verify no overlap with boot partition at LBA 32768
if [ $((16384 + UBOOT_SECTORS)) -gt 32768 ]; then
    echo "ERROR: u-boot.itb (${UBOOT_SECTORS} sectors) overlaps with boot partition at LBA 32768!"
    exit 1
fi

# -------------------------------------------------------------------
# Step 4: Set up loop device and format partitions
# -------------------------------------------------------------------
echo "==> Setting up loop device..."
LOSETUP_DEV=$(sudo losetup --show -fP "${DISK_IMG}")
echo "  Loop device: ${LOSETUP_DEV}"

cleanup() {
    echo "==> Cleaning up mounts and loop device..."
    sudo umount "${ROOTFS_MNT}/dev/pts" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}/dev" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}/proc" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}/sys" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}/run" 2>/dev/null || true
    sudo umount "${BOOT_MNT}" 2>/dev/null || true
    sudo umount "${OEM_MNT}" 2>/dev/null || true
    sudo umount "${USERDATA_MNT}" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}" 2>/dev/null || true
    sudo losetup -d "${LOSETUP_DEV}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Formatting partitions..."
sudo mkfs.ext4 -L boot -F -q "${LOSETUP_DEV}p1"
sudo mkfs.ext4 -L rootfs -F -q "${LOSETUP_DEV}p2"
sudo mkfs.ext4 -L oem -F -q "${LOSETUP_DEV}p3"
sudo mkfs.ext4 -L userdata -F -q "${LOSETUP_DEV}p4"

# -------------------------------------------------------------------
# Step 5: Mount and populate rootfs
# -------------------------------------------------------------------
ROOTFS_MNT=$(mktemp -d)
BOOT_MNT="${ROOTFS_MNT}/boot"
OEM_MNT="${ROOTFS_MNT}/oem"
USERDATA_MNT="${ROOTFS_MNT}/userdata"

echo "==> Mounting partitions..."
sudo mount "${LOSETUP_DEV}p2" "${ROOTFS_MNT}"
sudo mkdir -p "${BOOT_MNT}" "${OEM_MNT}" "${USERDATA_MNT}"
sudo mount "${LOSETUP_DEV}p1" "${BOOT_MNT}"
sudo mount "${LOSETUP_DEV}p3" "${OEM_MNT}"
sudo mount "${LOSETUP_DEV}p4" "${USERDATA_MNT}"

# Extract rootfs tarball
if [[ ! -f "${ROOTFS_TAR}" ]]; then
    echo "ERROR: rootfs tarball not found at ${ROOTFS_TAR}"
    exit 1
fi
echo "==> Extracting rootfs tarball..."
sudo tar -xzf "${ROOTFS_TAR}" -C "${ROOTFS_MNT}"

# -------------------------------------------------------------------
# Step 6: Copy boot assets
# -------------------------------------------------------------------
echo "==> Copying boot assets to /boot..."

# Kernel FIT image
if [[ -f "${BOOT_IMG}" ]]; then
    sudo cp "${BOOT_IMG}" "${BOOT_MNT}/boot.img"
    echo "  boot.img OK"
else
    echo "  WARNING: boot.img not found, skipping"
fi

# Base device tree
if ls "${BOOT_ASSETS}/"*.dtb 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/dtbs/"
    sudo cp "${BOOT_ASSETS}/"*.dtb "${BOOT_MNT}/dtbs/" 2>/dev/null || true
    echo "  DTBs OK"
fi

# DTS overlays
if ls "${BOOT_ASSETS}/overlays/"*.dtbo 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/overlays/"
    sudo cp "${BOOT_ASSETS}/overlays/"*.dtbo "${BOOT_MNT}/overlays/" 2>/dev/null || true
    echo "  DTS overlays OK"
fi

# extlinux config for U-Boot
if [[ -f "${BOOT_ASSETS}/extlinux/extlinux.conf" ]]; then
    sudo mkdir -p "${BOOT_MNT}/extlinux/"
    sudo cp "${BOOT_ASSETS}/extlinux/extlinux.conf" "${BOOT_MNT}/extlinux/"
    echo "  extlinux.conf OK"
fi

# U-Boot boot script
if [[ -f "${BOOT_ASSETS}/boot.scr" ]]; then
    sudo cp "${BOOT_ASSETS}/boot.scr" "${BOOT_MNT}/"
    echo "  boot.scr OK"
fi

# -------------------------------------------------------------------
# Step 7: Copy ubuntu-overlay files to rootfs
# -------------------------------------------------------------------
echo "==> Applying ubuntu-overlay..."

if [[ -d "${OVERLAY}/etc" ]]; then
    sudo cp -r "${OVERLAY}/etc/"* "${ROOTFS_MNT}/etc/"
fi
if [[ -d "${OVERLAY}/usr" ]]; then
    sudo cp -r "${OVERLAY}/usr/"* "${ROOTFS_MNT}/usr/"
fi

# -------------------------------------------------------------------
# Step 8: Install Rockchip and kernel .debs in chroot
# -------------------------------------------------------------------
echo "==> Installing custom packages..."

# Copy debs into chroot
if ls "${KERNEL_DEBS}/"*.deb 1>/dev/null 2>&1; then
    sudo mkdir -p "${ROOTFS_MNT}/tmp/debs/"
    sudo cp "${KERNEL_DEBS}/"*.deb "${ROOTFS_MNT}/tmp/debs/" 2>/dev/null || true
fi
if ls "${ROCKCHIP_DEBS}/"*.deb 1>/dev/null 2>&1; then
    sudo mkdir -p "${ROOTFS_MNT}/tmp/debs/"
    sudo cp "${ROCKCHIP_DEBS}/"*.deb "${ROOTFS_MNT}/tmp/debs/" 2>/dev/null || true
fi

# Mount virtual filesystems
sudo mount --bind /dev "${ROOTFS_MNT}/dev"
sudo mount --bind /dev/pts "${ROOTFS_MNT}/dev/pts"
sudo mount -t proc none "${ROOTFS_MNT}/proc"
sudo mount -t sysfs none "${ROOTFS_MNT}/sys"

# Chroot operations
sudo chroot "${ROOTFS_MNT}" /bin/bash << 'CHROOT_EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Install custom .deb packages
if ls /tmp/debs/*.deb 1>/dev/null 2>&1; then
    echo "  Installing custom .deb packages..."
    dpkg -i /tmp/debs/*.deb 2>&1 || true
    apt-get install -f -y -qq
    rm -rf /tmp/debs
fi

# Regenerate initramfs with platform modules
echo "  Updating initramfs..."
update-initramfs -u -k all 2>/dev/null || true

# Set hostname
echo "myd-lr3576" > /etc/hostname
echo "127.0.1.1 myd-lr3576" >> /etc/hosts

# Enable serial console on Rockchip debug UART
systemctl enable serial-getty@ttyFIQ0.service 2>/dev/null || true

# Disable unnecessary timers for embedded use
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable motd-news.timer 2>/dev/null || true
systemctl mask apt-daily.service 2>/dev/null || true
systemctl mask apt-daily-upgrade.service 2>/dev/null || true

# Disable snapd refresh timer if snapd is installed
systemctl disable snapd.refresh.timer 2>/dev/null || true
systemctl disable snapd.snap-refresh.timer 2>/dev/null || true

# Ensure the ubuntu user password is set correctly
if id ubuntu &>/dev/null; then
    echo "ubuntu:ubuntu" | chpasswd
fi

# Clean package cache
apt-get clean -y
rm -rf /var/lib/apt/lists/*

CHROOT_EOF

# -------------------------------------------------------------------
# Step 9: Finalize
# -------------------------------------------------------------------
echo "==> Syncing..."
sync

echo ""
echo "============================================="
echo "  Disk image created successfully!"
echo "  ${DISK_IMG}"
echo "  Size: $(du -h "${DISK_IMG}" | cut -f1)"
echo "============================================="
