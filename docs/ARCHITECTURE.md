# 系统架构

## 引导链

### Rockchip RK3576 引导流程

```
BootROM (mask ROM)
  → 从 eMMC/SD LBA 64 加载 idbloader.img
    idbloader = TPL (DDR init) + SPL (TrustZone setup, OP-TEE load)
  → SPL 从 LBA 16384 加载 u-boot.itb
    u-boot.itb = U-Boot proper + ATF (BL31) + OP-TEE
  → U-Boot 从 boot 分区加载 boot.img
    boot.img = FIT image (kernel Image + DTB + resource)
  → 内核启动 → initramfs → overlayfs → systemd
```

### LBA 偏移量计算

```
LBA 0:    Protective MBR
LBA 1:    GPT Header
LBA 2-33: GPT Partition Entries (128 entries × 128 bytes)
LBA 34-63: 保留 (未使用)
LBA 64:  idbloader (sector 0x40, 字节偏移 32768)
LBA 16384: u-boot.itb (sector 0x4000, 字节偏移 8388608)
LBA 32768: boot 分区起始 (sector 0x8000)
```

## 分区设计

### 为什么使用三个分区

| 分区 | 读写 | 理由 |
|------|------|------|
| boot | rw | 存放内核 FIT image + DTB + DTBO，U-Boot 直接读取 |
| rootfs | **ro** | 不可变基础系统，防止意外修改和断电损坏 |
| overlay | rw | 所有运行时修改的写入层 |

### OverlayFS 工作原理

```text
最终根文件系统 (/)  = overlayfs merge
  lowerdir = /ro           (rootfs 分区, read-only)
  upperdir = /overlay/upper (overlay 分区, writable)
  workdir  = /overlay/work  (overlay 分区, 临时)

操作效果:
  读取文件:   从 upper 读取 (若存在) 否则从 lower 读取
  写入文件:   写入 upper (copy-up 机制)
  删除文件:   在 upper 创建 whiteout 文件
```

### 系统升级与恢复

- **系统升级**: 替换 rootfs 分区内容 → 重启后 overlay 数据保留
- **出厂重置**: 清空 `/overlay/upper/` 和 `/overlay/work/` → 重启恢复初始状态
- **断电保护**: rootfs 只读不会损坏；overlay 上层损坏最多丢失 overlay 数据

## 关键组件

### initramfs overlay hook

位于 `etc/initramfs-tools/scripts/init-bottom/overlay`，在 root pivot 之前执行：

1. 等待 rootfs 分区和 overlay 分区就绪
2. 挂载 rootfs (ro) → /ro
3. 挂载 overlay (rw) → /overlay
4. 创建 overlayfs (lower=/ro, upper=/overlay/upper, work=/overlay/work) → ${rootmnt}
5. 移动 /ro 和 /overlay 到合并根文件系统内

### DTS Overlay

设备树覆盖层 (DTBO) 基于主 DTB (myd-lr3576.dtb)，通过 U-Boot extlinux.conf 中的 `fdtoverlays` 指令应用：

```conf
label Ubuntu 24.04 LTS (overlay)
    kernel /boot.img
    fdt /dtbs/myd-lr3576.dtb
    fdtoverlays /overlays/myd-lr3576-display.dtbo
    append ro rootwait root=PARTLABEL=rootfs rootfstype=ext4
```

可用的 DTBO 覆盖层：
- `myd-lr3576-camera1-ov13855-overlay.dtbo` — OV13855 摄像头
- `myd-lr3576-camera2-ar0234-overlay.dtbo` — AR0234 摄像头
- `myd-lr3576-camera3-ov5640-overlay.dtbo` — OV5640 摄像头
- `myd-lr3576-mipi-lt9611-hdmi-overlay.dtbo` — MIPI→HDMI (LT9611)
- `myd-lr3576-mipi-101c-overlay.dtbo` — MIPI 面板 (101C)

## ubuntu-image 集成

### 为什么手动组装磁盘

ubuntu-image classic 模式的 `setupBootloader` 状态 (源码: `classic_states.go:1359`) 只完全支持 GRUB。对于 `u-boot` 引导器类型，只打印警告：

```
WARNING: setting up bootloader u-boot not yet supported
```

因此采用混合方案：
1. ubuntu-image 构建 Ubuntu rootfs tarball (通过 seed germination + debootstrap)
2. assemble-disk.sh 手动放置 Rockchip 引导器 + 创建分区

### 构建流水线

```
image-definition.yaml → ubuntu-image classic → rootfs.tar.gz
                                                      ↓
                       assemble-disk.sh ← boot-assets/ + ubuntu-overlay/
                                                      ↓
                       ubuntu-24.04-*.img (最终镜像)
```

## QEMU 交叉编译

在 amd64 主机上构建 arm64 rootfs 使用：
- `qemu-aarch64-static` — arm64 用户模式模拟
- `binfmt_misc` — 内核自动识别 arm64 ELF 并调用 QEMU
- `debootstrap --arch arm64` — 创建 arm64 基础系统

已知问题：QEMU 模拟下 `py3compile` (Python 字节码编译) 可能因管道竞态条件触发 `BrokenPipeError`，解决方案是在 `install_packages` 之前将 `py3compile` 替换为 no-op。
