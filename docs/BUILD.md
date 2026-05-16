# 构建指南

## 前置条件

- `ubuntu-image` v3.x: `sudo snap install ubuntu-image --classic`
- `e2fsprogs`, `dosfstools`
- RK3576 SDK (用于内核/U-Boot/Rockchip 包的构建)

### 自托管 ARM64 Runner (构建快 10x)

## 常见问题

### `core snap not found`（preseed_image 阶段）

不要用 `sudo snap install core` —— 这把 core snap 装到宿主机，但 ubuntu-image 的
`snap-preseed` 需要从 Snap Store 下载作为镜像构建流程的一部分。

在 `image-definition.yaml` 中加 `extra-snaps: [snapd]`，ubuntu-image 会自己下载 snapd + core 依赖：

```yaml
# CI workflow 里
sudo snap install core  # 无用！snap-preseed 不走这里

# image-definition.yaml 里 — 正确做法
extra-snaps:
  - name: snapd
```

