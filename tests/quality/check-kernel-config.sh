#!/bin/bash
# Ubuntu Required Kernel Configuration Check
# Based on: Ubuntu Kernel Team requirements, systemd README, Debian kernel config policy

set -euo pipefail
cd "$(dirname "$0")/../.."

KCONFIG="${KCONFIG:-/tmp/kernel-config}"
PASS=0; FAIL=0; WARN=0

check() { local desc="$1" config="$2" required="${3:-y}"
    local val
    val=$(grep "^${config}=" "$KCONFIG" 2>/dev/null | cut -d= -f2)
    if [[ "$val" == "$required" ]]; then
        PASS=$((PASS+1))
    elif [[ "$required" == "y" && "$val" == "m" ]]; then
        echo "  WARN: ${desc} (${config}=m, should be =y)"
        WARN=$((WARN+1))
    elif [[ -z "$val" ]]; then
        echo "  FAIL: ${desc} (${config} is not set)"
        FAIL=$((FAIL+1))
    else
        echo "  FAIL: ${desc} (${config}=${val}, expected =${required})"
        FAIL=$((FAIL+1))
    fi
}

check_set() { local desc="$1" config="$2"
    if grep -q "^${config}=[ym]" "$KCONFIG" 2>/dev/null; then
        PASS=$((PASS+1))
    else
        echo "  FAIL: ${desc} (${config} is not set)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== Ubuntu Kernel Config Validation ==="
echo "Config: $KCONFIG"
echo ""

# --- Filesystem Support (required for boot) ---
echo "[Filesystems]"
check "ext4 (rootfs)" CONFIG_EXT4_FS y
check "FAT/VFAT (boot partition)" CONFIG_VFAT_FS y
check_set "OverlayFS (our overlay partition)" CONFIG_OVERLAY_FS

# --- Device Tree / DTS Overlay ---
echo "[Device Tree]"
check_set "Open Firmware (device tree)" CONFIG_OF
check "DTS overlay support" CONFIG_OF_OVERLAY y
check "ConfigFS overlay loading" CONFIG_OF_CONFIGFS y

# --- Block Devices ---
echo "[Block Devices]"
check "MMC/SD card support" CONFIG_MMC y
check "initramfs/initrd" CONFIG_BLK_DEV_INITRD y
check "loop device" CONFIG_BLK_DEV_LOOP y
check_set "devtmpfs (udev requirement)" CONFIG_DEVTMPFS

# --- systemd Requirements ---
echo "[systemd]"
check_set "cgroups" CONFIG_CGROUPS
check_set "cgroup v2 hierarchy" CONFIG_CGROUP_BPF
check_set "namespaces" CONFIG_NAMESPACES
check_set "PID namespaces" CONFIG_PID_NS
check_set "Network namespaces" CONFIG_NET_NS
check_set "auto devtmpfs mount" CONFIG_DEVTMPFS_MOUNT
check_set "tmpfs" CONFIG_TMPFS
check_set "POSIX timers" CONFIG_TIMERFD

# --- Networking ---
echo "[Networking]"
check_set "TCP/IP" CONFIG_INET
check_set "Unix domain sockets" CONFIG_UNIX
check_set "Packet sockets" CONFIG_PACKET
check_set "Netfilter/iptables" CONFIG_NETFILTER
check_set "Ethernet bridging" CONFIG_BRIDGE
check_set "VLAN 802.1q" CONFIG_VLAN_8021Q

# --- Security ---
echo "[Security]"
check_set "Syn cookies" CONFIG_SYN_COOKIES

# --- USB ---
echo "[USB]"
check_set "USB support" CONFIG_USB_SUPPORT
check_set "USB storage" CONFIG_USB_STORAGE
check_set "USB Gadget (device mode)" CONFIG_USB_GADGET

# --- Rockchip-specific ---
echo "[Rockchip]"
check_set "Rockchip IOMMU" CONFIG_ROCKCHIP_IOMMU
check_set "Rockchip thermal" CONFIG_ROCKCHIP_THERMAL
check_set "Rockchip SARADC" CONFIG_ROCKCHIP_SARADC

# --- GPIO ---
echo "[GPIO]"
check_set "GPIO sysfs" CONFIG_GPIO_SYSFS
check_set "sysfs" CONFIG_SYSFS

# --- EFI (UEFI boot compat) ---
echo "[EFI]"
check_set "EFI stub" CONFIG_EFI
check_set "EFI stub loader" CONFIG_EFI_STUB

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "=========================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
