# SoC 移植指南

## 概述

本项目设计为多 SoC 架构。添加新板 / SoC 只需修改配置文件，无需改动核心脚本。

## 架构原则

```text
boards/<board>.conf     ← 板级硬件配置 (唯一需要修改的文件)
ubuntu/
  image-definition.yaml ← Ubuntu 版本相关 (series, packages, seeds)
  assemble-disk.sh      ← 通用磁盘组装 (读取 board config)
  build.sh              ← 通用构建编排 (读取 board config)
  ubuntu-overlay/       ← 通用覆盖层 (fstab 使用 label, serial 使用模板)
```

## 添加新板子 (5 步)

### Step 1: 复制板子配置模板

```bash
cp boards/board-template.conf boards/rk3588-board.conf
```

### Step 2: 编辑配置文件

```bash
vim boards/rk3588-board.conf
```

必须修改的字段：

| 字段 | 说明 | 示例 |
|------|------|------|
| `BOARD_NAME` | 板子短名 | `rk3588-board` |
| `BOARD_VENDOR` | 厂商名 | `Orange Pi` |
| `BOARD_MODEL` | 型号 | `5 (RK3588S)` |
| `SOC_FAMILY` | SoC 家族 | `rockchip` |
| `SOC_MODEL` | SoC 型号 | `rk3588` |
| `IDBLOADER_SOURCE` | SPL loader 文件名 | `rk3588_spl_loader_v1.0.bin` |
| `UBOOT_SOURCE` | U-Boot 文件名 | `uboot.img` |
| `DTB_BASE` | 设备树基础文件名 | `rk3588-board.dtb` |
| `SERIAL_CONSOLE_DEV` | 串口设备名 | `ttyS2` (Allwinner=`ttyS0`, Rockchip=`ttyFIQ0`) |
| `SERIAL_CONSOLE_BAUD` | 串口波特率 | `1500000` (Rockchip) / `115200` (Allwinner) |
| `MALI_GPU_VARIANT` | GPU 型号 | `g610` (RK3588) / `g52` (RK3568) / `g31` (RK3576) |
| `KERNEL_MODULES` | 需要加载的内核模块列表 | 参考 Rockchip/Allwinner BSP |

### Step 3: 准备引导文件

```bash
# 从 SDK 复制引导器到 boot-assets/
export BOARD=rk3588-board
export SDK_PATH=/path/to/rk3588-board-sdk
./build.sh   # 自动从 SDK 复制引导文件
```

或手动：
```bash
cp $SDK_PATH/u-boot/rk3588_spl_loader_v1.0.bin ubuntu/boot-assets/idbloader.img
cp $SDK_PATH/u-boot/uboot.img ubuntu/boot-assets/u-boot.itb
cp $SDK_PATH/kernel/boot.img ubuntu/boot-assets/boot.img
cp $SDK_PATH/kernel/arch/arm64/boot/dts/rockchip/*.dtb ubuntu/boot-assets/
```

### Step 4: 编译 DTS Overlay（Rockchip）

```bash
cd $SDK_PATH/kernel-6.1
make ARCH=arm64 olddefconfig
make ARCH=arm64 dtbs

# 编译 overlays
for dts in arch/arm64/boot/dts/rockchip/rk3588-board-*-overlay.dts; do
    name=$(basename $dts .dts)
    gcc -E -nostdinc -I include -I arch/arm64/boot/dts \
        -undef -x assembler-with-cpp $dts | \
        scripts/dtc/dtc -@ -I dts -O dtb -o arch/arm64/boot/dts/rockchip/$name.dtbo -
done
```

### Step 5: 构建 & 测试

```bash
BOARD=rk3588-board ./build.sh
sudo BOARD=rk3588-board bash assemble-disk.sh
bash tests/qemu-test.sh
```

## 扩展到新的 SoC 家族 (Allwinner / Amlogic)

对于非 Rockchip SoC，需要额外注意：

### Allwinner (H616/H618/H6 等)

| 配置项 | 值 |
|--------|-----|
| `SOC_FAMILY` | `allwinner` |
| `SERIAL_CONSOLE_DEV` | `ttyS0` |
| `SERIAL_CONSOLE_BAUD` | `115200` |
| `KERNEL_BOOT_TYPE` | `fit` 或 `zimage` |
| `IDBLOADER_SOURCE` | (无 — Allwinner 使用不同引导方案) |
| `UBOOT_SOURCE` | `u-boot-sunxi-with-spl.bin` |
| `LBA_IDBLOADER` | `8` (U-Boot SPL at 8KB) |
| `LBA_UBOOT` | (不需要 — SPL 已包含在 u-boot-sunxi 中) |

### Amlogic (S905/S922 等)

| 配置项 | 值 |
|--------|-----|
| `SOC_FAMILY` | `amlogic` |
| `SERIAL_CONSOLE_DEV` | `ttyAML0` |
| `SERIAL_CONSOLE_BAUD` | `115200` |
| `IDBLOADER_SOURCE` | `u-boot.bin` |
| `UBOOT_SOURCE` | (不需要 — 单一 U-Boot 二进制) |

## 配置文件字段参考

查阅 `boards/board-template.conf` 和 `boards/rk3576.conf` 获取完整的字段列表和注释。

## FAQ

**Q: 如何选择 `PART_BOOT_START`？**
A: 查看 SDK 的 `rockdev/parameter.txt` 或 `sys_config.fex`。boot 分区起始扇区 = parameter.txt 中 `boot@` 后的值。需确保 u-boot + idbloader 不覆盖此分区。

**Q: 不同 SoC 的 serial console 设备名是什么？**
A: Rockchip=`ttyFIQ0` (FIQ debugger)，Allwinner=`ttyS0`，Amlogic=`ttyAML0`，通用=`ttyS2`。查看 kernel DTS 的 `chosen/stdout-path` 确定。

**Q: 我的板子需要不同的分区数量怎么办？**
A: 基础模板使用 3 分区 (boot + rootfs + overlay)。如需更多分区，修改 `assemble-disk.sh` 中的分区创建部分，并在 board config 中添加相应的变量。
