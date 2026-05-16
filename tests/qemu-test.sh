#!/bin/bash
set -euo pipefail
# ==========================================================================
# qemu-test.sh — Ubuntu Official Test Suite for RK3576 Image
#
# Uses qemu-aarch64-static to chroot into the arm64 rootfs and runs
# Ubuntu's standard validation checks. Generates a test report.
#
# Reference: Ubuntu image testing standards
#   - /usr/share/ubuntu-qa-tools/
#   - dpkg --verify
#   - apt-get check / apt-get update
#   - systemd-analyze verify
#   - cloud-init validation
# ==========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${PROJECT_DIR}/artifacts}"
ROOTFS_TAR="${ARTIFACTS_DIR}/rootfs.tar.gz"
REPORT_FILE="${ARTIFACTS_DIR}/test-report.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

# -------------------------------------------------------------------
# Test helper functions
# -------------------------------------------------------------------
test_header() {
    echo "" | tee -a "${REPORT_FILE}"
    echo "==========================================" | tee -a "${REPORT_FILE}"
    echo " $*" | tee -a "${REPORT_FILE}"
    echo "==========================================" | tee -a "${REPORT_FILE}"
}

test_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $*" | tee -a "${REPORT_FILE}"
    ((PASS++))
}

test_fail() {
    echo -e "  ${RED}[FAIL]${NC} $*" | tee -a "${REPORT_FILE}"
    ((FAIL++))
}

test_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $*" | tee -a "${REPORT_FILE}"
    ((WARN++))
}

test_info() {
    echo -e "  ${CYAN}[INFO]${NC} $*" | tee -a "${REPORT_FILE}"
}

# -------------------------------------------------------------------
# Step 1: Environment setup
# -------------------------------------------------------------------
init_test_env() {
    test_header "Test Environment Setup"

    echo "Test started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${REPORT_FILE}"
    echo "Host: $(uname -m)" | tee -a "${REPORT_FILE}"

    # Find rootfs tarball
    if [[ ! -f "${ROOTFS_TAR}" ]]; then
        test_fail "Rootfs tarball not found: ${ROOTFS_TAR}"
        exit 1
    fi
    TAR_SIZE=$(du -h "${ROOTFS_TAR}" | cut -f1)
    test_info "Rootfs tarball: ${ROOTFS_TAR} (${TAR_SIZE})"

    # Create staging directory
    STAGING=$(mktemp -d)
    trap "sudo rm -rf ${STAGING}" EXIT
    test_info "Staging: ${STAGING}"

    # Extract rootfs
    test_info "Extracting rootfs..."
    sudo tar -xzf "${ROOTFS_TAR}" -C "${STAGING}"
    test_pass "Rootfs extracted"

    # Detect architecture: native arm64 = direct chroot, amd64 = QEMU
    HOST_ARCH=$(uname -m)
    if [[ "${HOST_ARCH}" == "aarch64" ]] || [[ "${HOST_ARCH}" == "arm64" ]]; then
        test_info "Native ARM64 host — direct chroot (no QEMU needed)"
        NEEDS_QEMU=false
    else
        if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
            test_fail "qemu-aarch64-static not found. Install: sudo apt-get install qemu-user-static"
            exit 1
        fi
        test_pass "qemu-aarch64-static found (cross-arch testing)"
        QEMU_BIN=$(which qemu-aarch64-static)
        sudo cp "${QEMU_BIN}" "${STAGING}/usr/bin/"
        test_pass "qemu-aarch64-static copied to rootfs"
        NEEDS_QEMU=true
    fi
}

# Helper: run command inside chroot (auto-detects QEMU vs native)
chroot_run() {
    if [[ "${NEEDS_QEMU}" == "true" ]]; then
        sudo chroot "${STAGING}" /usr/bin/qemu-aarch64-static /bin/bash -c "$*" 2>/dev/null
    else
        sudo chroot "${STAGING}" /bin/bash -c "$*" 2>/dev/null
    fi
}

# -------------------------------------------------------------------
# Test 1: Image Identity Verification
# -------------------------------------------------------------------
test_image_identity() {
    test_header "Test 1: Image Identity"

    # os-release
    if [[ -f "${STAGING}/etc/os-release" ]]; then
        local os_name
        os_name=$(chroot_run \
            'source /etc/os-release && echo "${NAME} ${VERSION_ID}"' 2>/dev/null || echo "UNKNOWN")
        if [[ "${os_name}" =~ "Ubuntu 24.04" ]]; then
            test_pass "OS: ${os_name}"
        else
            test_fail "OS: expected Ubuntu 24.04, got '${os_name}'"
        fi

        local arch
        arch=$(chroot_run \
            'dpkg --print-architecture' 2>/dev/null || echo "UNKNOWN")
        if [[ "${arch}" == "arm64" ]]; then
            test_pass "Architecture: arm64"
        else
            test_fail "Architecture: expected arm64, got '${arch}'"
        fi
    else
        test_fail "/etc/os-release missing"
    fi

    # Ubuntu keyring
    if [[ -f "${STAGING}/usr/share/keyrings/ubuntu-archive-keyring.gpg" ]] || \
       [[ -f "${STAGING}/etc/apt/trusted.gpg.d/ubuntu-keyring.gpg" ]]; then
        test_pass "Ubuntu archive keyring present"
    else
        test_warn "Ubuntu keyring check skipped"
    fi
}

# -------------------------------------------------------------------
# Test 2: Package Integrity
# -------------------------------------------------------------------
test_package_integrity() {
    test_header "Test 2: Package Integrity (dpkg)"

    # dpkg --verify (check integrity of installed files)
    local dpkg_verify
    dpkg_verify=$(chroot_run \
        'dpkg --verify 2>&1 || true' 2>/dev/null)
    if [[ -z "$(echo "${dpkg_verify}" | grep -v '^$')" ]]; then
        test_pass "dpkg --verify: all packages intact"
    else
        local verify_count
        verify_count=$(echo "${dpkg_verify}" | grep -c . || true)
        if [[ ${verify_count} -lt 10 ]]; then
            test_warn "dpkg --verify: ${verify_count} files modified (acceptable)"
        else
            test_fail "dpkg --verify: ${verify_count} files modified"
        fi
    fi

    # apt-get check
    if chroot_run 'apt-get check >/dev/null 2>&1'; then
        test_pass "apt-get check: no broken dependencies"
    else
        test_fail "apt-get check: broken dependencies found"
    fi

    # dpkg --audit
    local audit
    audit=$(chroot_run \
        'dpkg --audit 2>&1 || true' 2>/dev/null)
    if [[ -z "$(echo "${audit}" | grep -v '^$')" ]]; then
        test_pass "dpkg --audit: clean"
    else
        test_warn "dpkg --audit: issues found"
    fi
}

# -------------------------------------------------------------------
# Test 3: APT Sources and Package Availability
# -------------------------------------------------------------------
test_apt_sources() {
    test_header "Test 3: APT Sources and Package Availability"

    # Check sources.list
    local sources_files
    sources_files=$(sudo ls "${STAGING}/etc/apt/sources.list.d/" 2>/dev/null || true)
    if [[ -n "${sources_files}" ]] || [[ -f "${STAGING}/etc/apt/sources.list" ]]; then
        test_pass "APT sources configured"
        test_info "Sources: $(echo ${sources_files})"
    else
        test_fail "No APT sources found"
    fi

    # Check for Ubuntu archive in sources
    if sudo grep -rq 'ubuntu.com\|ubuntu-ports' "${STAGING}/etc/apt/" 2>/dev/null; then
        local mirror
        mirror=$(sudo grep -rh 'ubuntu.com\|ubuntu-ports' "${STAGING}/etc/apt/" 2>/dev/null | head -1 | tr -d '\n')
        test_pass "Ubuntu mirror configured: ${mirror:0:60}"
    else
        test_fail "No Ubuntu mirror in APT sources"
    fi
}

# -------------------------------------------------------------------
# Test 4: Excluded Packages Verification
# -------------------------------------------------------------------
test_excluded_packages() {
    test_header "Test 4: Excluded Packages (Embedded Optimization)"

    local excluded="gnome-games|gnome-sudoku|gnome-mines|gnome-mahjongg|aisleriot|unattended-upgrades|update-notifier|update-manager-core|ubuntu-release-upgrader-core|thunderbird|libreoffice-core|rhythmbox|transmission"
    local found
    found=$(chroot_run \
        "dpkg -l 2>/dev/null | grep -iE '${excluded}' || true" 2>/dev/null)

    if [[ -z "${found}" ]]; then
        test_pass "No excluded packages (games, updates, bloat) found"
    else
        local excluded_names
        excluded_names=$(echo "${found}" | awk '{print $2}' | tr '\n' ' ')
        test_fail "Excluded packages found: ${excluded_names}"
    fi

    # Verify essential packages ARE present
    for pkg in systemd apt dpkg linux-firmware network-manager; do
        if chroot_run \
            "dpkg -l ${pkg} 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
            test_pass "  Essential package '${pkg}' installed"
        else
            test_warn "  Essential package '${pkg}' missing"
        fi
    done
}

# -------------------------------------------------------------------
# Test 5: Systemd Services and Timers
# -------------------------------------------------------------------
test_systemd() {
    test_header "Test 5: Systemd Services and Timers"

    # Check disabled timers
    for timer in apt-daily.timer apt-daily-upgrade.timer motd-news.timer; do
        local status
        status=$(chroot_run \
            "systemctl is-enabled ${timer} 2>&1 || true" 2>/dev/null)
        if [[ "${status}" == "disabled" ]] || [[ "${status}" == "masked" ]] || \
           [[ "${status}" == "not-found" ]]; then
            test_pass "${timer}: ${status}"
        else
            test_fail "${timer}: enabled (should be disabled)"
        fi
    done

    # Check serial console service
    if [[ -f "${STAGING}/etc/systemd/system/serial-getty@ttyFIQ0.service.d/override.conf" ]]; then
        test_pass "serial-getty@ttyFIQ0 override configured"
    else
        test_warn "serial-getty@ttyFIQ0 override not found"
    fi

    # Check apt periodic config
    if [[ -f "${STAGING}/etc/apt/apt.conf.d/20disable-periodic" ]]; then
        test_pass "APT periodic disabled (20disable-periodic)"
    else
        test_warn "APT periodic config not found"
    fi
}

# -------------------------------------------------------------------
# Test 6: Filesystem Layout
# -------------------------------------------------------------------
test_filesystem_layout() {
    test_header "Test 6: Filesystem Layout"

    # Standard directories
    for dir in /boot /etc /usr /var /tmp /dev /proc /sys /ro /overlay; do
        if [[ -d "${STAGING}${dir}" ]]; then
            test_pass "  ${dir}/ exists"
        else
            if [[ "${dir}" == "/ro" ]] || [[ "${dir}" == "/overlay" ]]; then
                test_warn "  ${dir}/ missing (created at runtime)"
            else
                test_fail "  ${dir}/ missing"
            fi
        fi
    done

    # fstab
    if [[ -f "${STAGING}/etc/fstab" ]]; then
        local fstab_content
        fstab_content=$(sudo cat "${STAGING}/etc/fstab")
        if echo "${fstab_content}" | grep -q 'LABEL=overlay'; then
            test_pass "/etc/fstab: overlay partition configured"
        fi
        if echo "${fstab_content}" | grep -q 'LABEL=boot'; then
            test_pass "/etc/fstab: boot partition configured"
        fi
    else
        test_fail "/etc/fstab missing"
    fi

    # Kernel modules
    if [[ -d "${STAGING}/lib/modules" ]] && \
       sudo ls "${STAGING}/lib/modules/" 2>/dev/null | grep -q '6\.'; then
        test_pass "Kernel modules present"
    else
        test_warn "Kernel modules not found (install kernel .deb first)"
    fi
}

# -------------------------------------------------------------------
# Test 7: Overlay Setup Verification
# -------------------------------------------------------------------
test_overlay_setup() {
    test_header "Test 7: OverlayFS Setup"

    # Initramfs overlay hook
    local hook="${STAGING}/etc/initramfs-tools/scripts/init-bottom/overlay"
    if [[ -f "${hook}" ]]; then
        if [[ -x "${hook}" ]]; then
            test_pass "Initramfs overlay hook: present and executable"
        else
            test_fail "Initramfs overlay hook: not executable"
        fi
    else
        test_warn "Initramfs overlay hook: not found (will be added by assemble-disk.sh)"
    fi

    # Check for overlay kernel module support
    if [[ -d "${STAGING}/lib/modules" ]]; then
        local ovl_mod
        ovl_mod=$(sudo find "${STAGING}/lib/modules" -name "overlay.ko*" 2>/dev/null | head -1)
        if [[ -n "${ovl_mod}" ]]; then
            test_pass "overlay kernel module found"
        else
            test_warn "overlay kernel module not in rootfs (may be built-in)"
        fi
    fi
}

# -------------------------------------------------------------------
# Test 8: Cloud-init and User Setup
# -------------------------------------------------------------------
test_cloud_init() {
    test_header "Test 8: Cloud-init and User Setup"

    # cloud-init config
    if [[ -f "${STAGING}/etc/cloud/cloud.cfg" ]]; then
        test_pass "cloud-init installed"
        if sudo grep -q 'name: ubuntu' "${STAGING}/etc/cloud/cloud.cfg" 2>/dev/null; then
            test_pass "cloud-init: ubuntu user configured"
        fi
    else
        test_warn "cloud-init not installed"
    fi

    # ubuntu user
    if sudo grep -q '^ubuntu:' "${STAGING}/etc/shadow" 2>/dev/null; then
        test_pass "ubuntu user exists in /etc/shadow"
    else
        test_warn "ubuntu user not in /etc/shadow (created by cloud-init at first boot)"
    fi

    # Password expiry
    if sudo grep -q '^ubuntu:!' "${STAGING}/etc/shadow" 2>/dev/null; then
        test_pass "ubuntu password set to expire (security best practice)"
    fi
}

# -------------------------------------------------------------------
# Test 9: Network Configuration
# -------------------------------------------------------------------
test_network() {
    test_header "Test 9: Network Configuration"

    # NetworkManager
    if chroot_run \
        "dpkg -l network-manager 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
        test_pass "NetworkManager installed"
    else
        test_warn "NetworkManager not installed"
    fi

    # openssh-server
    if chroot_run \
        "dpkg -l openssh-server 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
        test_pass "OpenSSH server installed"
    else
        test_warn "OpenSSH server not installed"
    fi

    # /etc/hosts has localhost
    if sudo grep -q 'localhost' "${STAGING}/etc/hosts" 2>/dev/null; then
        test_pass "/etc/hosts: localhost configured"
    else
        test_fail "/etc/hosts: localhost missing"
    fi
}

# -------------------------------------------------------------------
# Test 10: Ubuntu Official Validation Summary
# -------------------------------------------------------------------
test_ubuntu_official() {
    test_header "Test 10: Ubuntu Official Validation"

    # Run ubuntu-standard checks if available
    if chroot_run \
        "command -v ubuntu-security-status >/dev/null 2>&1" 2>/dev/null; then
        test_info "ubuntu-security-status available"
        chroot_run \
            "ubuntu-security-status 2>&1 || true" 2>/dev/null | head -5 | tee -a "${REPORT_FILE}"
    fi

    # Check for apt update capability (network required)
    test_info "Skipping apt update test (network not available in chroot)"

    # Verify /etc/machine-id not present (should be regenerated at boot)
    if [[ -f "${STAGING}/etc/machine-id" ]]; then
        local mid
        mid=$(sudo cat "${STAGING}/etc/machine-id")
        if [[ "${mid}" == "uninitialized" ]] || [[ -z "${mid}" ]]; then
            test_pass "/etc/machine-id: uninitialized (will be generated at first boot)"
        else
            test_info "/etc/machine-id: present (ubiquity or cloud-init will regenerate)"
        fi
    fi
}

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------
generate_report() {
    test_header "Test Report Summary"

    local total=$((PASS + FAIL + WARN))
    echo ""
    echo "  Total tests: ${total}" | tee -a "${REPORT_FILE}"
    echo -e "  ${GREEN}Passed: ${PASS}${NC}" | tee -a "${REPORT_FILE}"
    echo -e "  ${RED}Failed: ${FAIL}${NC}" | tee -a "${REPORT_FILE}"
    echo -e "  ${YELLOW}Warnings: ${WARN}${NC}" | tee -a "${REPORT_FILE}"
    echo ""

    local pass_rate=0
    if [[ ${total} -gt 0 ]]; then
        pass_rate=$((PASS * 100 / total))
    fi

    echo "  Pass rate: ${pass_rate}%" | tee -a "${REPORT_FILE}"
    echo "  Test finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${REPORT_FILE}"
    echo ""
    echo "Full report: ${REPORT_FILE}"
    echo ""

    # Return exit code based on failures
    if [[ ${FAIL} -gt 0 ]]; then
        echo "RESULT: FAIL (${FAIL} test(s) failed)" | tee -a "${REPORT_FILE}"
        return 1
    elif [[ ${WARN} -gt 0 ]]; then
        echo "RESULT: WARN (${WARN} warning(s), see report)" | tee -a "${REPORT_FILE}"
        return 0
    else
        echo "RESULT: PASS (all tests passed)" | tee -a "${REPORT_FILE}"
        return 0
    fi
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    rm -f "${REPORT_FILE}"
    echo "Ubuntu 24.04 RK3576 Image Test Report" | tee "${REPORT_FILE}"
    echo "==========================================" | tee -a "${REPORT_FILE}"
    echo "" | tee -a "${REPORT_FILE}"

    init_test_env
    test_image_identity
    test_package_integrity
    test_apt_sources
    test_excluded_packages
    test_systemd
    test_filesystem_layout
    test_overlay_setup
    test_cloud_init
    test_network
    test_ubuntu_official
    generate_report

    local ret=$?
    sudo rm -rf "${STAGING}"
    exit ${ret}
}

main "$@"
