# Rockchip RK3576 Ubuntu 镜像构建

基于 `ubuntu-image` (Canonical 官方工具) 为 Rockchip RK3576 (RK3576) 构建 Ubuntu 24.04 / 26.04 LTS 镜像。

## 快速开始

```bash
# 1. 构建 rootfs (需要 sudo)
cd myd-lr3576
sudo /snap/bin/ubuntu-image classic image-definition.yaml --output-dir artifacts/

# 2. 组装磁盘镜像
sudo bash assemble-disk.sh

# 3. 运行测试
bash tests/qemu-test.sh
```

## 目录结构

```
ubuntu/
  image-definition.yaml          # Ubuntu 24.04 镜像定义
  image-definition-questing.yaml # Ubuntu 26.04 镜像定义
  build.sh                       # 构建编排脚本
  assemble-disk.sh               # 磁盘镜像组装 (GPT分区 + bootloader)
  boot-assets/                   # 引导文件 (DTB, DTBO, extlinux, boot.cmd)
  ubuntu-overlay/                # 根文件系统覆盖层 (fstab, initramfs hook)
  rockchip-debs/                 # Rockchip 定制 .deb 包 (MPP, RGA, Mali 等)
  kernel-debs/                   # 内核 .deb 包
  tests/                         # QEMU 测试套件
  artifacts/                     # 构建产物 (rootfs.tar.gz, .img, manifest)
```

## 分区布局

| 分区 | 大小 | 标签 | 文件系统 | 用途 |
|------|------|------|----------|------|
| (raw LBA 64) | — | — | — | idbloader (SPL + DDR init) |
| (raw LBA 16384) | — | — | — | u-boot.itb |
| p1 boot | 256MB | LABEL=boot | ext4 | Kernel FIT image + DTB + DTBO |
| p2 rootfs | 6GB | LABEL=rootfs | ext4 (ro) | Ubuntu 只读基础系统 |
| p3 overlay | 512MB | LABEL=overlay | ext4 (rw) | OverlayFS upper + work 目录 |

## 启动流程

```
BootROM → idbloader (LBA 64) → U-Boot (LBA 16384) → boot.img (FIT: kernel+DTB)
  → 内核挂载 rootfs (/ro, ro) + overlay (/overlay, rw)
  → initramfs hook: overlayfs merge → / (writable)
```

## 关键设计决策

1. **ubuntu-image 构建 rootfs，手动组装 bootloader** — ubuntu-image 的 U-Boot 支持不完整，只处理 SecureBoot 文件
2. **只读 rootfs + OverlayFS 覆盖层** — 断电安全，系统升级只需替换 rootfs 分区
3. **DTS Overlay 支持** — 设备树覆盖层方便修改硬件配置，无需重新编译完整 DTB

## GitHub Actions CI

编译通过 GitHub Actions 自动执行：
- `ubuntu-24.04` (amd64) runner + QEMU arm64 交叉编译
- 支持 workflow_dispatch 选择 Ubuntu 系列 (noble/questing)
- 构建产物保留 7 天

## SDK 依赖

RK3576 SDK 路径通过环境变量 `SDK_PATH` 配置，默认为 `/media/loh/rockchip/lr3576_v2/`。

## 扩展到其他 SoC

```bash
# 1. 复制板子配置
cp boards/board-template.conf boards/rk3588-board.conf
# 2. 编辑配置
vim boards/rk3588-board.conf
# 3. 构建
BOARD=rk3588-board ./build.sh
```

详见 [SoC 移植指南](docs/PORTING.md) 和 [架构文档](docs/ARCHITECTURE.md)。
