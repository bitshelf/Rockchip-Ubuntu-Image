#!/bin/bash
# Quality Check: No hardcoded board values in scripts
# Ensures all board-specific values come from config files

set -euo pipefail
cd "$(dirname "$0")/../.."

PASS=0; FAIL=0

check() {
    local desc="$1"; local pattern="$2"; local file="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL [$desc]: hardcoded value found in $file"
        grep -n "$pattern" "$file"
        FAIL=$((FAIL+1))
    else
        PASS=$((PASS+1))
    fi
}

echo "=== Quality Check: No Hardcoded Board Values ==="

# Board names must not be hardcoded in build scripts
check "board-name" 'myd-lr3576\|MYD-LR3576' ubuntu/build.sh
check "board-name" 'MYiR\|orangepi' ubuntu/assemble-disk.sh

# Paths must use variables, not absolute paths
check "abs-path" '/home/loh/' ubuntu/build.sh
check "abs-path" '/media/loh/' ubuntu/assemble-disk.sh

# SDK_PATH must not have a default
! grep -q 'SDK_PATH:-' ubuntu/build.sh && PASS=$((PASS+1)) || {
    echo "  FAIL: SDK_PATH has default value"; FAIL=$((FAIL+1)); }

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
