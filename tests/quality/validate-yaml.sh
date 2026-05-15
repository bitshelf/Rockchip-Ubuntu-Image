#!/bin/bash
# Quality Check: Validate image definition YAML syntax and required fields

set -euo pipefail
cd "$(dirname "$0")/../.."

PASS=0; FAIL=0

echo "=== Quality Check: YAML Validation ==="

for yaml in ubuntu/image-definition.yaml ubuntu/image-definition-questing.yaml; do
    [[ -f "$yaml" ]] || { echo "  FAIL: $yaml not found"; FAIL=$((FAIL+1)); continue; }

    # Check required top-level keys
    for key in name architecture series class rootfs artifacts; do
        if grep -q "^${key}:" "$yaml"; then
            PASS=$((PASS+1))
        else
            echo "  FAIL: missing '${key}:' in $yaml"
            FAIL=$((FAIL+1))
        fi
    done

    # Check arm64
    grep -q 'architecture: arm64' "$yaml" && PASS=$((PASS+1)) || {
        echo "  FAIL: architecture not arm64 in $yaml"; FAIL=$((FAIL+1)); }

    # Check no cloud-image seed
    ! grep -q 'cloud-image' "$yaml" && PASS=$((PASS+1)) || {
        echo "  FAIL: cloud-image seed present in $yaml"; FAIL=$((FAIL+1)); }

    # Check HTTPS seed URLs
    ! grep -q 'git://' "$yaml" && PASS=$((PASS+1)) || {
        echo "  FAIL: git:// protocol in $yaml (use https://)"; FAIL=$((FAIL+1)); }
done

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
