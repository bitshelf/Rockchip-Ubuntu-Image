# U-Boot boot script for Rockchip RK3576
# Compiled with: mkimage -A arm64 -O linux -T script -C none -d boot.cmd boot.scr

# Load kernel FIT image from boot partition
load mmc ${mmcdev}:${mmcpart} ${kernel_addr_r} /boot.img

# Load base device tree
load mmc ${mmcdev}:${mmcpart} ${fdt_addr_r} /dtbs/myd-lr3576.dtb

# Apply DTS overlays
fdt addr ${fdt_addr_r}
fdt resize 65536
load mmc ${mmcdev}:${mmcpart} ${overlay_addr} /overlays/myd-lr3576-display.dtbo
fdt apply ${overlay_addr}

# Set bootargs for read-only root with overlay
setenv bootargs earlycon=uart8250,mmio32,0x2a340000 console=ttyFIQ0,1500000n8 ro rootwait root=PARTLABEL=rootfs rootfstype=ext4

# Boot the FIT image
bootm ${kernel_addr_r}
