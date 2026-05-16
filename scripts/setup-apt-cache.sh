#!/bin/bash
set -euo pipefail
# ==========================================================================
# setup-apt-cache.sh — Install and configure apt-cacher-ng for local builds
#
# After setup, subsequent ubuntu-image builds use the local cache
# instead of re-downloading packages from the mirror on each build.
#
# Cache location: /var/cache/apt-cacher-ng/
# Cache size limit: 50 GB (configurable)
# ==========================================================================

CACHE_SIZE_GB="${CACHE_SIZE_GB:-50}"

echo "==> Installing apt-cacher-ng..."
sudo apt-get install -y -qq apt-cacher-ng

echo "==> Configuring apt-cacher-ng..."

# Configure cache size and pass-through for Ubuntu ports
sudo tee /etc/apt-cacher-ng/acng.conf.d/ubuntu-ports.conf > /dev/null << 'EOF'
# Cache configuration for Ubuntu image building
CacheDir: /var/cache/apt-cacher-ng
LogDir: /var/log/apt-cacher-ng
Port: 3142
BindAddress: 0.0.0.0

# Remap Ubuntu ports mirror
Remap-ubports: https://mirrors.ustc.edu.cn/ubuntu-ports/ ; file:ubports_mirrors
# Keep packages for 60 days
ExTreshold: 60
# Maximum cache size
MaxInFlight: 250

# Pass-through mode: if not in cache, download from upstream
PassThroughPattern: .*
EOF

# Set cache size limit (convert GB to bytes for the config)
sudo sed -i "s/^ExTreshold.*/ExTreshold: 60/" /etc/apt-cacher-ng/acng.conf 2>/dev/null || true

echo "==> Restarting apt-cacher-ng..."
sudo systemctl restart apt-cacher-ng
sudo systemctl enable apt-cacher-ng

echo ""
echo "============================================"
echo " apt-cacher-ng is ready!"
echo " Proxy: http://localhost:3142"
echo " Cache: /var/cache/apt-cacher-ng/"
echo ""
echo " To use in image builds:"
echo "   The build system auto-detects the cache."
echo "   From QEMU chroot: http://10.0.2.2:3142"
echo "   From native host: http://localhost:3142"
echo "============================================"
