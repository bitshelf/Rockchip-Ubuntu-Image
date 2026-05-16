#!/bin/bash
# Disable services unnecessary for embedded systems
# Called during image assembly

set -euo pipefail

systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable motd-news.timer 2>/dev/null || true
systemctl mask apt-daily.service 2>/dev/null || true
systemctl mask apt-daily-upgrade.service 2>/dev/null || true
systemctl disable snapd.refresh.timer 2>/dev/null || true
systemctl disable snapd.snap-refresh.timer 2>/dev/null || true

exit 0
