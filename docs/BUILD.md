# 构建指南

## 前置条件

- `ubuntu-image` v3.x: `sudo snap install ubuntu-image --classic`
- `qemu-user-static` + `binfmt-support` (arm64 交叉编译)
- `sgdisk` (gdisk 包)
- `e2fsprogs`, `dosfstools`
- RK3576 SDK (用于内核/U-Boot/Rockchip 包的构建)

## 本地构建

### 1. 准备引导文件

```bash
# 必须设置 SDK_PATH，指向 SDK 根目录
export SDK_PATH=/path/to/rk3576-sdk

# 从 SDK 复制引导器（具体文件名参考 boards/<your-board>.conf）
cp $SDK_PATH/u-boot/rk3576_spl_loader_v1.09.108.bin boot-assets/idbloader.img
cp $SDK_PATH/u-boot/uboot.img boot-assets/u-boot.itb
cp $SDK_PATH/kernel-6.1/boot.img boot-assets/boot.img
cp $SDK_PATH/kernel-6.1/arch/arm64/boot/dts/rockchip/*.dtb boot-assets/
cp $SDK_PATH/kernel-6.1/arch/arm64/boot/dts/rockchip/*-overlay.dtbo boot-assets/overlays/
```

### 2. 构建 rootfs tarball

```bash
cd myd-lr3576
mkdir -p artifacts

# 构建 Ubuntu 24.04 (noble)
sudo /snap/bin/ubuntu-image classic \
  image-definition.yaml \
  --output-dir artifacts/ \
  --workdir /tmp/ui-work

# 构建 Ubuntu 26.04 (questing)
sudo /snap/bin/ubuntu-image classic \
  image-definition-questing.yaml \
  --output-dir artifacts/
```

### 3. QEMU 交叉编译修复 (amd64 主机)

在 amd64 主机上，`py3compile` 的 QEMU 模拟可能失败。使用两阶段构建：

```bash
# 阶段 1: 构建 chroot 但不安装包
sudo /snap/bin/ubuntu-image classic image-definition.yaml \
  --output-dir artifacts/ --workdir /tmp/ui-work \
  --until install_packages

# 阶段 2: 打补丁 py3compile
echo '#!/bin/bash\nexit 0' | sudo tee /tmp/ui-work/chroot/usr/bin/py3compile
sudo chmod +x /tmp/ui-work/chroot/usr/bin/py3compile

# 阶段 3: 继续安装
sudo /snap/bin/ubuntu-image classic image-definition.yaml \
  --output-dir artifacts/ --workdir /tmp/ui-work --resume
```

### 4. 组装磁盘镜像

```bash
sudo bash assemble-disk.sh
```

输出：`artifacts/ubuntu-24.04-preinstalled-server-arm64+myd-lr3576.img`

### 5. 运行测试

```bash
bash tests/qemu-test.sh
```

测试报告：`artifacts/test-report.txt`

## CI 构建

GitHub Actions 自动在 `ubuntu-24.04` (amd64) runner 上构建。

### 手动触发

1. GitHub → Actions → Build Ubuntu Image for RK3576 → Run workflow
2. 选择 Ubuntu 系列 (noble/questing)
3. 构建产物在 Actions artifacts 中下载

### 自托管 ARM64 Runner (推荐，构建快 10x)

```bash
# 在 ARM64 主机上
mkdir ~/actions-runner && cd ~/actions-runner
curl -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-arm64-*.tar.gz | tar xz
./config.sh --url https://github.com/bitshelf/Rockchip-Ubuntu-Image --token <TOKEN> --labels self-hosted,linux,arm64
./run.sh
```

然后在仓库 Settings → Variables 添加 `RUNNER_LABEL = self-hosted`。

## 常见问题

### `firmware-linux-free` 包不存在

已在 `image-definition.yaml` 中移除。Ubuntu 24.04 中此包已废弃。

### `core snap not found`

已通过移除 `cloud-image` seed 解决。此 seed 会引入 snap 预置依赖。

### `BrokenPipeError` in py3compile

QEMU arm64 模拟中 Python 字节码编译的管道竞态。使用两阶段构建方法解决。

### snap install 在 CI 中失败

GitHub Actions runner 不支持 snap。改用 Go 源码构建 ubuntu-image。

### 本地构建需要 sudo 密码

使用 `echo "password" | sudo -S command` 或配置 NOPASSWD sudoers。
