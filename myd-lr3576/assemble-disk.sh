#!/bin/bash
set -euo pipefail

# ==========================================================================
# assemble-disk.sh — Assemble final RK3576 disk image
#
# Partition layout (from rockdev/parameter.txt, adapted for Ubuntu):
#   LBA 0-33:     GPT headers (protective MBR + GPT table)
#   LBA 64:       idbloader (SPL + DDR init, raw binary)
#   LBA 16384:    u-boot.itb (U-Boot proper, raw binary)
#   LBA 32768:    boot partition (256MB ext4, LABEL=boot)
#   after boot:   rootfs partition (~6GB ext4, LABEL=rootfs, READ-ONLY)
#   after rootfs: overlay partition (512MB ext4, LABEL=overlay, WRITABLE)
#
# OverlayFS setup:
#   - rootfs is the "lower" layer (read-only)
#   - overlay partition holds "upper" and "work" directories
#   - initramfs merge-mounts them as the root filesystem
#   - All runtime modifications go to overlay partition
#   - Factory reset = wipe overlay partition
#   - System upgrade = replace rootfs partition
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
BOOT_ASSETS="${SCRIPT_DIR}/boot-assets"
OVERLAY_DIR="${SCRIPT_DIR}/ubuntu-overlay"
ROCKCHIP_DEBS="${SCRIPT_DIR}/rockchip-debs"
KERNEL_DEBS="${SCRIPT_DIR}/kernel-debs"

DISK_IMG="${ARTIFACTS_DIR}/ubuntu-24.04-preinstalled-server-arm64+myd-lr3576.img"
DISK_SIZE_MB=8192  # 8 GB for SD card
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"

IDBLOADER="${BOOT_ASSETS}/idbloader.img"
UBOOT="${BOOT_ASSETS}/u-boot.itb"
BOOT_IMG="${BOOT_ASSETS}/boot.img"

# Partition sizes (in MB)
BOOT_SIZE=256
ROOTFS_SIZE=6144
OVERLAY_SIZE=512

# -------------------------------------------------------------------
# Step 1: Create sparse disk image
# -------------------------------------------------------------------
echo "==> Creating sparse disk image (${DISK_SIZE_MB}MB)..."
truncate -s "${DISK_SIZE_MB}M" "${DISK_IMG}"

# -------------------------------------------------------------------
# Step 2: Create GPT partition table
# -------------------------------------------------------------------
echo "==> Creating GPT partition table..."
sgdisk --clear "${DISK_IMG}"

# Partition 1: boot (ext4) at LBA 32768 (matches Rockchip parameter.txt boot@0x8000)
sgdisk --new=1:32768:+${BOOT_SIZE}M \
  --typecode=1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  --change-name=1:boot "${DISK_IMG}"

# Partition 2: rootfs (ext4, read-only base system)
sgdisk --new=2:0:+${ROOTFS_SIZE}M \
  --typecode=2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=2:rootfs "${DISK_IMG}"

# Partition 3: overlay (ext4, writable overlay upper layer)
sgdisk --new=3:0:+${OVERLAY_SIZE}M \
  --typecode=3:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=3:overlay "${DISK_IMG}"

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

ROOTFS_MNT=""
BOOT_MNT=""
OVERLAY_MNT=""

cleanup() {
    echo "==> Cleaning up mounts and loop device..."
    for mnt in "/dev/pts" "/dev" "/proc" "/sys" "/run"; do
        sudo umount "${ROOTFS_MNT}${mnt}" 2>/dev/null || true
    done
    sudo umount "${BOOT_MNT}" 2>/dev/null || true
    sudo umount "${OVERLAY_MNT}" 2>/dev/null || true
    sudo umount "${ROOTFS_MNT}" 2>/dev/null || true
    sudo losetup -d "${LOSETUP_DEV}" 2>/dev/null || true
    for d in "${ROOTFS_MNT}" "${BOOT_MNT}" "${OVERLAY_MNT}"; do
        rmdir "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

echo "==> Formatting partitions..."
sudo mkfs.ext4 -L boot -F -q "${LOSETUP_DEV}p1"
sudo mkfs.ext4 -L rootfs -F -q "${LOSETUP_DEV}p2"
sudo mkfs.ext4 -L overlay -F -q "${LOSETUP_DEV}p3"

# -------------------------------------------------------------------
# Step 5: Mount and populate
# -------------------------------------------------------------------
ROOTFS_MNT=$(mktemp -d)
BOOT_MNT=$(mktemp -d)
OVERLAY_MNT=$(mktemp -d)

echo "==> Mounting partitions..."
sudo mount "${LOSETUP_DEV}p2" "${ROOTFS_MNT}"
sudo mount "${LOSETUP_DEV}p1" "${BOOT_MNT}"
sudo mount "${LOSETUP_DEV}p3" "${OVERLAY_MNT}"

# Create overlay directory structure on overlay partition
sudo mkdir -p "${OVERLAY_MNT}/upper"
sudo mkdir -p "${OVERLAY_MNT}/work"
sudo chmod 0755 "${OVERLAY_MNT}/upper" "${OVERLAY_MNT}/work"

# Extract rootfs tarball
if [[ ! -f "${ROOTFS_TAR}" ]]; then
    echo "ERROR: rootfs tarball not found at ${ROOTFS_TAR}"
    exit 1
fi
echo "==> Extracting rootfs tarball..."
sudo tar -xzf "${ROOTFS_TAR}" -C "${ROOTFS_MNT}"

# -------------------------------------------------------------------
# Step 6: Copy boot assets to boot partition
# -------------------------------------------------------------------
echo "==> Copying boot assets to boot partition..."

if [[ -f "${BOOT_IMG}" ]]; then
    sudo cp "${BOOT_IMG}" "${BOOT_MNT}/boot.img"
    echo "  boot.img OK"
else
    echo "  WARNING: boot.img not found, skipping"
fi

if ls "${BOOT_ASSETS}/"*.dtb 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/dtbs/"
    sudo cp "${BOOT_ASSETS}/"*.dtb "${BOOT_MNT}/dtbs/" 2>/dev/null || true
    echo "  DTBs OK"
fi

if ls "${BOOT_ASSETS}/overlays/"*.dtbo 1>/dev/null 2>&1; then
    sudo mkdir -p "${BOOT_MNT}/overlays/"
    sudo cp "${BOOT_ASSETS}/overlays/"*.dtbo "${BOOT_MNT}/overlays/" 2>/dev/null || true
    echo "  DTS overlays OK"
fi

if [[ -f "${BOOT_ASSETS}/extlinux/extlinux.conf" ]]; then
    sudo mkdir -p "${BOOT_MNT}/extlinux/"
    sudo cp "${BOOT_ASSETS}/extlinux/extlinux.conf" "${BOOT_MNT}/extlinux/"
    echo "  extlinux.conf OK"
fi

if [[ -f "${BOOT_ASSETS}/boot.scr" ]]; then
    sudo cp "${BOOT_ASSETS}/boot.scr" "${BOOT_MNT}/"
    echo "  boot.scr OK"
fi

# -------------------------------------------------------------------
# Step 7: Apply ubuntu-overlay files to rootfs
# -------------------------------------------------------------------
echo "==> Applying ubuntu-overlay..."

if [[ -d "${OVERLAY_DIR}/etc" ]]; then
    sudo cp -r "${OVERLAY_DIR}/etc/"* "${ROOTFS_MNT}/etc/"
fi
if [[ -d "${OVERLAY_DIR}/usr" ]]; then
    sudo cp -r "${OVERLAY_DIR}/usr/"* "${ROOTFS_MNT}/usr/"
fi

# -------------------------------------------------------------------
# Step 8: Install Rockchip and kernel .debs in chroot
# -------------------------------------------------------------------
echo "==> Installing custom packages..."

if ls "${KERNEL_DEBS}/"*.deb 1>/dev/null 2>&1; then
    sudo mkdir -p "${ROOTFS_MNT}/tmp/debs/"
    sudo cp "${KERNEL_DEBS}/"*.deb "${ROOTFS_MNT}/tmp/debs/" 2>/dev/null || true
fi
if [[ -d "${ROCKCHIP_DEBS}" ]] && ls "${ROCKCHIP_DEBS}/"*.deb 1>/dev/null 2>&1; then
    sudo mkdir -p "${ROOTFS_MNT}/tmp/debs/"
    sudo cp "${ROCKCHIP_DEBS}/"*.deb "${ROOTFS_MNT}/tmp/debs/" 2>/dev/null || true
fi

# Mount virtual filesystems
sudo mount --bind /dev "${ROOTFS_MNT}/dev"
sudo mount --bind /dev/pts "${ROOTFS_MNT}/dev/pts"
sudo mount -t proc none "${ROOTFS_MNT}/proc"
sudo mount -t sysfs none "${ROOTFS_MNT}/sys"

# -------------------------------------------------------------------
# Step 9: Chroot finalization
# -------------------------------------------------------------------
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

# Regenerate initramfs (includes overlay mount hook)
echo "  Updating initramfs..."
update-initramfs -u -k all 2>/dev/null || true

# Set hostname
echo "myd-lr3576" > /etc/hostname
echo "127.0.1.1 myd-lr3576" >> /etc/hosts

# Enable serial console on Rockchip debug UART
systemctl enable serial-getty@ttyFIQ0.service 2>/dev/null || true

# Disable unnecessary timers for embedded use
for timer in apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
             snapd.refresh.timer snapd.snap-refresh.timer; do
    systemctl disable "$timer" 2>/dev/null || true
done
for svc in apt-daily.service apt-daily-upgrade.service; do
    systemctl mask "$svc" 2>/dev/null || true
done

# Ensure ubuntu user password is set
if id ubuntu &>/dev/null; then
    echo "ubuntu:ubuntu" | chpasswd
fi

# Clean up
apt-get clean -y
rm -rf /var/lib/apt/lists/*

CHROOT_EOF

# Unmount virtual filesystems
sudo umount "${ROOTFS_MNT}/dev/pts" 2>/dev/null || true
sudo umount "${ROOTFS_MNT}/dev" 2>/dev/null || true
sudo umount "${ROOTFS_MNT}/proc" 2>/dev/null || true
sudo umount "${ROOTFS_MNT}/sys" 2>/dev/null || true

# -------------------------------------------------------------------
# Step 10: Create symlink /boot -> boot partition mount point in rootfs
# The rootfs /boot directory will be empty; actual boot files are on
# the boot partition, mounted at /boot via fstab at runtime.
# During initramfs, we don't yet have /boot mounted; the kernel
# FIT image is loaded by U-Boot directly from the boot partition.
# -------------------------------------------------------------------

# -------------------------------------------------------------------
# Step 11: Finalize
# -------------------------------------------------------------------
echo "==> Syncing..."
sync

echo ""
echo "============================================="
echo "  Disk image created successfully!"
echo "  ${DISK_IMG}"
echo "  Size: $(du -h "${DISK_IMG}" | cut -f1)"
echo ""
echo "  Partition layout:"
echo "    p1: boot    (256MB, ext4, LABEL=boot)"
echo "    p2: rootfs  (${ROOTFS_SIZE}MB, ext4, LABEL=rootfs, READ-ONLY)"
echo "    p3: overlay (${OVERLAY_SIZE}MB, ext4, LABEL=overlay, WRITABLE)"
echo ""
echo "  OverlayFS: lower=rootfs(ro) + upper=overlay/upper(rw) -> /"
echo "============================================="
