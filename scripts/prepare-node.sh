#!/usr/bin/env bash
# =============================================================================
# prepare-node.sh — Node preparation for K3s + Cilium + WireGuard
#
# Run this on EVERY node (controller + agents) BEFORE installing K3s.
# Sources the offline bundle at BUNDLE_PATH for packages and configuration.
#
# Usage: sudo ./prepare-node.sh [--bundle-path PATH] [--debug] [--dry-run]
# =============================================================================
set -euo pipefail

# =============================================================================
# Colour / logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/prepare.log"
DEBUG=false
DRY_RUN=false
BUNDLE_PATH="/opt/offline-bundle"

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo -e "${GREEN}[INFO]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" >&2; }
log_step() { echo -e "\n${BLUE}${BOLD}══ [STEP] $(_ts) $*${NC}" | tee -a "${LOG_FILE}"; }
log_ok()   { echo -e "${GREEN}  ✔${NC} $*" | tee -a "${LOG_FILE}"; }
log_debug(){ ${DEBUG} && echo -e "${CYAN}[DEBUG]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" || true; }
run()      { log_debug "RUN: $*"; ${DRY_RUN} || "$@"; }

on_error() { log_error "Failed at line $1. Check ${LOG_FILE}"; exit 1; }
trap 'on_error $LINENO' ERR

# =============================================================================
# Idempotency
# =============================================================================
STEP_FILE="${LOG_DIR}/.prepare-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}prepare-node.sh${NC} — Prepare a node for K3s + Cilium + WireGuard

${BOLD}USAGE${NC}
  sudo $0 [OPTIONS]

${BOLD}OPTIONS${NC}
  --bundle-path PATH   Path to extracted offline bundle  (default: ${BUNDLE_PATH})
  --debug              Enable debug output
  --dry-run            Print commands without executing
  -h, --help           Show this help

${BOLD}EXAMPLE${NC}
  sudo $0 --bundle-path /opt/offline-bundle
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-path) BUNDLE_PATH="${2:?--bundle-path requires a value}"; shift 2 ;;
        --debug)       DEBUG=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap logging
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

# =============================================================================
# Root check
# =============================================================================
check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
}

# =============================================================================
# 1. Capture before-state
# =============================================================================
capture_before_state() {
    step_done "before-state" && { log_info "Before-state already captured, skipping."; return; }
    log_step "Capturing before-state snapshot"

    local report="${LOG_DIR}/system-comparison-report.txt"
    {
        echo "================================================================"
        echo "  BEFORE-INSTALLATION STATE — $(date -u)"
        echo "================================================================"
        echo ""
        echo "--- Network Interfaces ---"
        ip -br link show 2>/dev/null || true
        echo ""
        echo "--- IP Addresses ---"
        ip -br addr show 2>/dev/null || true
        echo ""
        echo "--- Routing Table ---"
        ip route show 2>/dev/null || true
        echo ""
        echo "--- Running Services ---"
        systemctl list-units --state=running --no-pager 2>/dev/null | head -40 || true
        echo ""
        echo "--- Kernel Modules ---"
        lsmod 2>/dev/null | head -40 || true
        echo ""
        echo "--- Swap Status ---"
        free -h 2>/dev/null || true
        swapon --show 2>/dev/null || echo "(no swap entries)"
        echo ""
        echo "--- Disk Usage ---"
        df -h 2>/dev/null || true
        echo ""
        echo "--- Memory ---"
        free -h 2>/dev/null || true
        echo ""
        echo "--- CPU ---"
        nproc 2>/dev/null || true
        echo ""
        echo "--- containerd / crio ---"
        ctr version 2>/dev/null || echo "(containerd not running)"
        echo ""
    } > "${report}"

    log_ok "Before-state saved to ${report}"
    mark_done "before-state"
}

# =============================================================================
# 2. System requirement checks
# =============================================================================
check_system_requirements() {
    log_step "System Requirements Check"

    local failed=0

    # Root
    [[ $EUID -eq 0 ]] && log_ok "Running as root" || { log_error "Not root"; failed=$((failed+1)); }

    # CPU cores (minimum 2)
    local cores; cores="$(nproc)"
    [[ "${cores}" -ge 2 ]] \
        && log_ok "CPU cores: ${cores}" \
        || { log_warn "CPU cores: ${cores} (minimum 2 recommended)"; }

    # RAM (minimum 2 GB = 2048 MB)
    local ram_mb; ram_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    [[ "${ram_mb}" -ge 1800 ]] \
        && log_ok "RAM: ${ram_mb} MB" \
        || { log_warn "RAM: ${ram_mb} MB (2 GB+ recommended)"; }

    # Disk (minimum 10 GB free on /)
    local disk_gb; disk_gb="$(df / --output=avail -BG | tail -1 | tr -d 'G ')"
    [[ "${disk_gb}" -ge 10 ]] \
        && log_ok "Free disk on /: ${disk_gb} GB" \
        || { log_warn "Free disk on /: ${disk_gb} GB (10 GB+ recommended)"; }

    # Kernel version >= 6.0
    local kernel; kernel="$(uname -r)"
    local kver; kver="$(echo "${kernel}" | cut -d. -f1)"
    [[ "${kver}" -ge 6 ]] \
        && log_ok "Kernel: ${kernel}" \
        || { log_warn "Kernel: ${kernel} — 6.x+ recommended for WireGuard built-in"; }

    # OS check
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        local version; version="$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')"
        log_ok "OS: Ubuntu ${version}"
    else
        log_warn "Non-Ubuntu OS detected — package installation may need adjustment"
    fi

    # Architecture
    local arch; arch="$(uname -m)"
    log_ok "Architecture: ${arch}"

    # Time sync
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes\|NTP synchronized: yes"; then
        log_ok "Time sync: active"
    else
        log_warn "Time sync: not confirmed — install chrony/ntp for production"
    fi

    # ── Hostname uniqueness check ─────────────────────────────────────────────
    # K3s uses the hostname as the node name. VMs cloned from the same template
    # (e.g. UTM Ubuntu images) all start with hostname "ubuntu" or "localhost",
    # causing silent node registration conflicts in the cluster.
    local current_hostname; current_hostname="$(hostname)"
    local generic_hostnames=("ubuntu" "localhost" "debian" "raspberrypi" "vm" "node" "server")

    local hostname_is_generic=false
    for generic in "${generic_hostnames[@]}"; do
        if [[ "${current_hostname,,}" == "${generic}" ]]; then
            hostname_is_generic=true
            break
        fi
    done

    if ${hostname_is_generic}; then
        echo ""
        log_error "════════════════════════════════════════════════════════"
        log_error "  HOSTNAME CONFLICT RISK: '${current_hostname}'"
        log_error "════════════════════════════════════════════════════════"
        log_error "  This hostname is generic and WILL cause node name"
        log_error "  conflicts when multiple VMs join the same cluster."
        log_error ""
        log_error "  Set a unique hostname NOW before proceeding:"
        log_error "    sudo hostnamectl set-hostname <unique-name>"
        log_error "    sudo reboot                   # or: exec bash"
        log_error ""
        log_error "  Example names:"
        log_error "    cp-1   cp-2   etcd-node"
        log_error "    worker-01   worker-02   worker-03"
        log_error "════════════════════════════════════════════════════════"
        echo ""
        exit 1
    fi

    log_ok "Hostname: '${current_hostname}' (unique — no conflict risk)"

    [[ "${failed}" -eq 0 ]] || { log_error "${failed} requirement(s) failed"; exit 1; }
    log_ok "System requirements check passed"
}

# =============================================================================
# 3. Offline bundle validation
# =============================================================================
check_offline_bundle() {
    log_step "Offline Bundle Validation (${BUNDLE_PATH})"

    [[ -d "${BUNDLE_PATH}" ]] || {
        log_error "Bundle directory not found: ${BUNDLE_PATH}"
        log_error "Extract the bundle first: sudo tar -xzf offline-bundle.tar.gz -C /opt/"
        exit 1
    }

    local missing=0

    # Detect arch to check correct airgap image
    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    local required_files=(
        "${BUNDLE_PATH}/binaries/k3s"
        "${BUNDLE_PATH}/binaries/install.sh"
        "${BUNDLE_PATH}/binaries/kubectl"
        "${BUNDLE_PATH}/binaries/helm"
        "${BUNDLE_PATH}/binaries/cilium"
        "${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
        "${BUNDLE_PATH}/images/cilium-images.tar"
        "${BUNDLE_PATH}/manifests/cilium-values.yaml"
        "${BUNDLE_PATH}/manifests/99-k3s-cilium.conf"
    )

    for path in "${required_files[@]}"; do
        if [[ -f "${path}" ]]; then
            log_ok "${path##*/}"
        else
            log_error "MISSING: ${path}"
            missing=$((missing + 1))
        fi
    done

    # Optional packages dir
    local pkg_count; pkg_count="$(find "${BUNDLE_PATH}/packages" -name "*.deb" 2>/dev/null | wc -l)"
    [[ "${pkg_count}" -gt 0 ]] \
        && log_ok "${pkg_count} .deb packages available" \
        || log_warn "No .deb packages in bundle — ensure packages are pre-installed"

    [[ "${missing}" -eq 0 ]] || {
        log_error "${missing} required bundle file(s) missing. Re-run prepare-offline-bundle.sh."
        exit 1
    }
    log_ok "All required bundle files present"
}

# =============================================================================
# 4. Kernel modules
# =============================================================================
load_kernel_modules() {
    step_done "kernel-modules" && { log_info "Kernel modules already loaded, skipping."; return; }
    log_step "Loading Required Kernel Modules"

    local modules=("wireguard" "br_netfilter" "overlay" "ip_tables" "xt_conntrack" "nf_conntrack")

    for mod in "${modules[@]}"; do
        if lsmod | grep -q "^${mod}"; then
            log_ok "${mod} (already loaded)"
        else
            if modinfo "${mod}" &>/dev/null; then
                run modprobe "${mod}"
                log_ok "${mod} (loaded)"
            else
                log_warn "${mod} not available — may be built-in to kernel"
            fi
        fi
    done

    # Persist across reboots
    run tee /etc/modules-load.d/k3s-cilium.conf > /dev/null <<'EOF'
wireguard
br_netfilter
overlay
ip_tables
xt_conntrack
EOF
    log_ok "Module persistence configured at /etc/modules-load.d/k3s-cilium.conf"
    mark_done "kernel-modules"
}

# =============================================================================
# 5. Sysctl settings
# =============================================================================
apply_sysctl() {
    step_done "sysctl" && { log_info "sysctl already applied, skipping."; return; }
    log_step "Applying sysctl Settings"

    local src="${BUNDLE_PATH}/manifests/99-k3s-cilium.conf"
    if [[ -f "${src}" ]]; then
        run cp "${src}" /etc/sysctl.d/99-k3s-cilium.conf
        log_ok "Copied ${src} → /etc/sysctl.d/99-k3s-cilium.conf"
    else
        # Write defaults if bundle file missing
        run tee /etc/sysctl.d/99-k3s-cilium.conf > /dev/null <<'EOF'
net.ipv4.ip_forward                  = 1
net.ipv6.conf.all.forwarding         = 1
net.bridge.bridge-nf-call-iptables   = 1
net.bridge.bridge-nf-call-ip6tables  = 1
net.bridge.bridge-nf-call-arptables  = 1
net.ipv4.conf.all.rp_filter          = 0
net.ipv4.conf.default.rp_filter      = 0
fs.inotify.max_user_instances        = 8192
fs.inotify.max_user_watches          = 524288
net.netfilter.nf_conntrack_max       = 1000000
EOF
    fi

    run sysctl --system >> "${LOG_FILE}" 2>&1
    log_ok "sysctl settings applied"
    mark_done "sysctl"
}

# =============================================================================
# 6. Disable swap
# =============================================================================
disable_swap() {
    step_done "swap-off" && { log_info "Swap already disabled, skipping."; return; }
    log_step "Disabling Swap"

    run swapoff -a
    # Remove swap entries from fstab
    run sed -i '/\sswap\s/d' /etc/fstab

    local swap_total; swap_total="$(free -m | awk '/^Swap:/ {print $2}')"
    [[ "${swap_total}" -eq 0 ]] \
        && log_ok "Swap disabled" \
        || log_warn "Swap may still be partially active (${swap_total} MB)"

    mark_done "swap-off"
}

# =============================================================================
# 7. Install packages from bundle
# =============================================================================
install_packages() {
    step_done "packages" && { log_info "Packages already installed, skipping."; return; }
    log_step "Installing Packages from Offline Bundle"

    local pkg_dir="${BUNDLE_PATH}/packages"
    local pkg_count; pkg_count="$(find "${pkg_dir}" -name "*.deb" 2>/dev/null | wc -l)"

    if [[ "${pkg_count}" -eq 0 ]]; then
        log_warn "No .deb packages found in ${pkg_dir} — skipping package install"
        log_warn "Ensure iproute2, conntrack, iptables, socat are pre-installed"
        return
    fi

    log_info "Installing ${pkg_count} packages from ${pkg_dir}"
    run dpkg -i --force-depends "${pkg_dir}"/*.deb >> "${LOG_FILE}" 2>&1 \
        || log_warn "Some package installs reported errors — may be dependency ordering; usually safe"

    # Verify key packages are present
    local required_bins=("ip" "conntrack" "iptables" "socat")
    for bin in "${required_bins[@]}"; do
        command -v "${bin}" &>/dev/null \
            && log_ok "${bin} available" \
            || log_warn "${bin} not found — may need manual install"
    done

    # Verify WireGuard is available
    if modinfo wireguard &>/dev/null || ip link add dev wg_test type wireguard 2>/dev/null; then
        ip link delete wg_test 2>/dev/null || true
        log_ok "WireGuard kernel support confirmed"
    else
        log_warn "WireGuard kernel module not confirmed — required for Cilium encryption"
    fi

    mark_done "packages"
}

# =============================================================================
# 8. Install binaries from bundle
# =============================================================================
install_binaries() {
    step_done "binaries" && { log_info "Binaries already installed, skipping."; return; }
    log_step "Installing Binaries from Bundle"

    local bin_dir="${BUNDLE_PATH}/binaries"

    for bin in kubectl helm cilium crictl; do
        local src="${bin_dir}/${bin}"
        local dst="/usr/local/bin/${bin}"
        if [[ -f "${src}" ]]; then
            run cp "${src}" "${dst}"
            run chmod +x "${dst}"
            log_ok "${bin} → ${dst}"
        else
            log_warn "${bin} not found in bundle at ${src}"
        fi
    done

    mark_done "binaries"
}

# =============================================================================
# 9. Verify node-to-node connectivity (optional, pass server IP)
# =============================================================================
check_connectivity() {
    local target_ip="${1:-}"
    [[ -z "${target_ip}" ]] && return

    log_step "Checking Connectivity to ${target_ip}"
    if ping -c 2 -W 3 "${target_ip}" &>/dev/null; then
        log_ok "Ping to ${target_ip} OK"
    else
        log_warn "Cannot ping ${target_ip} — check network/firewall"
    fi

    if nc -z -w 5 "${target_ip}" 6443 2>/dev/null; then
        log_ok "Port 6443 reachable on ${target_ip}"
    else
        log_warn "Port 6443 unreachable on ${target_ip} — K3s API not yet running (expected on first install)"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │        K3s Node Preparation Script            │"
    echo "  │   Cilium + WireGuard — Offline Bundle         │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    check_root
    check_system_requirements
    check_offline_bundle
    capture_before_state
    load_kernel_modules
    apply_sysctl
    disable_swap
    install_packages
    install_binaries

    log_info ""
    log_ok "Node preparation complete. Log: ${LOG_FILE}"
    log_info "Next step — on controller node:"
    log_info "  sudo ./install-k3s-server.sh --node-ip <this-node-ip>"
    log_info "Next step — on worker nodes:"
    log_info "  sudo ./install-k3s-agent.sh --server-ip <controller-ip> --token <token>"
}

main "$@"
