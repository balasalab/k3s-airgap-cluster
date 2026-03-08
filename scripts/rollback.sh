#!/usr/bin/env bash
# =============================================================================
# rollback.sh — Clean up and restore node to pre-installation state
#
# Removes K3s, Cilium, CNI config, WireGuard interfaces, binaries, and
# system changes made during installation.
#
# Run on the node you want to clean up (server or agent).
#
# Usage: sudo ./rollback.sh [--server | --agent | --all] [OPTIONS]
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/rollback.log"
DEBUG=false
DRY_RUN=false

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo -e "${GREEN}[INFO]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" >&2; }
log_step() { echo -e "\n${BLUE}${BOLD}══ [STEP] $(_ts) $*${NC}" | tee -a "${LOG_FILE}"; }
log_ok()   { echo -e "${GREEN}  ✔${NC} $*" | tee -a "${LOG_FILE}"; }
log_skip() { echo -e "${CYAN}  ↷${NC} $* (skipped — not found)" | tee -a "${LOG_FILE}"; }
log_debug(){ ${DEBUG} && echo -e "${CYAN}[DEBUG]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" || true; }
run()      { log_debug "RUN: $*"; ${DRY_RUN} || "$@"; }

# Non-fatal run — logs error but continues
run_ok() { log_debug "RUN (non-fatal): $*"; ${DRY_RUN} && return; "$@" 2>>"${LOG_FILE}" || true; }

on_error() { log_error "Unexpected failure at line $1. Check ${LOG_FILE}"; }
trap 'on_error $LINENO' ERR

# =============================================================================
# Idempotency — tracks which cleanup steps completed so re-runs skip them
# =============================================================================
STEP_FILE="${LOG_DIR}/.rollback-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Defaults
# =============================================================================
ROLLBACK_SERVER=false
ROLLBACK_AGENT=false
ROLLBACK_PREPARE=false   # revert prepare-node.sh changes (sysctl, packages)
ROLLBACK_ETCD=false      # remove etcd service + data (install-etcd.sh)
ROLLBACK_LOGS=false      # wipe /var/log/k3s-install for a fully clean slate
FORCE=false

# Installed binaries list (same set as prepare-node.sh / install scripts place)
INSTALLED_BINS=(
    /usr/local/bin/k3s
    /usr/local/bin/kubectl
    /usr/local/bin/helm
    /usr/local/bin/cilium
    /usr/local/bin/crictl
)

# K3s-managed symlinks that the installer creates
K3S_SYMLINKS=(
    /usr/local/bin/k3s-agent
    /usr/local/bin/k3s-server
    /usr/local/bin/k3s-etcd-snapshot
    /usr/local/bin/k3s-token
    /usr/local/bin/kubectl
    /usr/local/bin/crictl
    /usr/local/bin/ctr
)

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}rollback.sh${NC} — Restore node to pre-installation state

${BOLD}USAGE${NC}
  sudo $0 [--server] [--agent] [--prepare] [OPTIONS]

${BOLD}SCOPE FLAGS (pick one or more)${NC}
  --server     Roll back K3s server (control plane) installation
  --agent      Roll back K3s agent (worker node) installation
  --prepare    Also revert prepare-node.sh changes (sysctl, modules)
  --etcd       Remove etcd service and data (for etcd node cleanup)
  --all        Roll back everything (server + agent + prepare + etcd + logs)

${BOLD}OPTIONS${NC}
  --force      Skip confirmation prompt
  --debug      Enable debug output
  --dry-run    Print commands without executing
  -h, --help   Show this help

${BOLD}EXAMPLES${NC}
  # Roll back a worker node only
  sudo $0 --agent --force

  # Roll back the control plane fully (K3s + system changes)
  sudo $0 --server --prepare --force

  # Roll back etcd node only
  sudo $0 --etcd --force

  # Full clean slate — everything removed (controller node)
  sudo $0 --all --force

  # Full clean slate — worker node
  sudo $0 --agent --prepare --force

${BOLD}CLEAN SLATE PROCEDURE (to test from scratch)${NC}
  # 1. On EACH worker node:
  #    sudo ./rollback.sh --agent --prepare --force && sudo reboot

  # 2. On the CONTROL PLANE (single-CP setup):
  #    sudo ./rollback.sh --server --prepare --force && sudo reboot

  # 3. On the etcd node (HA setup):
  #    sudo ./rollback.sh --etcd --prepare --force && sudo reboot

${BOLD}WHAT THIS REMOVES${NC}
  K3s services (k3s / k3s-agent), Cilium, CNI config, WireGuard interfaces,
  installed binaries (k3s, kubectl, helm, cilium, crictl), K3s data directories,
  kubeconfig files, step-tracking files, sysctl and kernel module changes.
  With --etcd: etcd service, data, config, user, binaries.
  With --all:  all of the above + /var/log/k3s-install/ log directory.
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)    ROLLBACK_SERVER=true;                               shift ;;
        --agent)     ROLLBACK_AGENT=true;                                shift ;;
        --prepare)   ROLLBACK_PREPARE=true;                              shift ;;
        --etcd)      ROLLBACK_ETCD=true;                                 shift ;;
        --all)       ROLLBACK_SERVER=true; ROLLBACK_AGENT=true;
                     ROLLBACK_PREPARE=true; ROLLBACK_ETCD=true;
                     ROLLBACK_LOGS=true;                                 shift ;;
        --force)     FORCE=true;                                         shift ;;
        --debug)     DEBUG=true;                                         shift ;;
        --dry-run)   DRY_RUN=true;                                       shift ;;
        -h|--help)   usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# Default: roll back whatever is installed on this node
if ! ${ROLLBACK_SERVER} && ! ${ROLLBACK_AGENT} && ! ${ROLLBACK_PREPARE}; then
    log_warn "No scope specified — auto-detecting..."

    # Detect via running service OR leftover step files (handles partially cleaned installs)
    { systemctl is-active --quiet k3s 2>/dev/null || [[ -f "${LOG_DIR}/.server-steps" ]]; } \
        && ROLLBACK_SERVER=true || true
    { systemctl is-active --quiet k3s-agent 2>/dev/null || [[ -f "${LOG_DIR}/.agent-steps" ]]; } \
        && ROLLBACK_AGENT=true || true
    [[ -f "${LOG_DIR}/.prepare-steps" ]] && ROLLBACK_PREPARE=true || true
    { systemctl is-active --quiet etcd 2>/dev/null || [[ -f "${LOG_DIR}/.etcd-steps" ]]; } \
        && ROLLBACK_ETCD=true || true

    if ! ${ROLLBACK_SERVER} && ! ${ROLLBACK_AGENT} && ! ${ROLLBACK_PREPARE} && ! ${ROLLBACK_ETCD}; then
        log_warn "Nothing detected to roll back. Exiting."
        exit 0
    fi
    log_info "Detected: server=${ROLLBACK_SERVER}  agent=${ROLLBACK_AGENT}  prepare=${ROLLBACK_PREPARE}  etcd=${ROLLBACK_ETCD}"
fi

# =============================================================================
# Bootstrap
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }

# =============================================================================
# Confirmation
# =============================================================================
confirm_rollback() {
    if ${FORCE} || ${DRY_RUN}; then
        return 0
    fi

    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║               ⚠  DESTRUCTIVE OPERATION ⚠                ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This will permanently remove:"
    ${ROLLBACK_SERVER}  && echo "    • K3s control plane (k3s service + all cluster data)"
    ${ROLLBACK_AGENT}   && echo "    • K3s agent (k3s-agent service)"
    ${ROLLBACK_ETCD}    && echo "    • etcd service, data (/var/lib/etcd), config (/etc/etcd)"
    echo "    • Cilium CNI and WireGuard interfaces"
    echo "    • Installed binaries: k3s, kubectl, helm, cilium, crictl"
    echo "    • /etc/rancher, /var/lib/rancher, /var/lib/kubelet"
    ${ROLLBACK_PREPARE} && echo "    • sysctl and kernel module changes from prepare-node.sh"
    ${ROLLBACK_LOGS}    && echo "    • /var/log/k3s-install/ (all logs and step files)"
    echo ""
    read -rp "  Type 'yes' to confirm: " answer
    if [[ "${answer}" != "yes" ]]; then
        log_info "Rollback cancelled by user."
        exit 0
    fi
    echo ""
}

# =============================================================================
# 1. Stop and disable K3s services
# =============================================================================
stop_k3s_services() {
    step_done "stop-services" && { log_info "Services already stopped, skipping."; return; }
    log_step "Stopping K3s Services"

    for svc in k3s k3s-agent; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            log_info "Stopping ${svc}..."
            run_ok systemctl stop "${svc}"
            log_ok "${svc} stopped"
        else
            log_skip "${svc} service"
        fi

        if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            run_ok systemctl disable "${svc}"
            log_ok "${svc} disabled"
        fi
    done
    mark_done "stop-services"
}

# =============================================================================
# 2. Run official K3s uninstall scripts
# =============================================================================
run_k3s_uninstall() {
    step_done "k3s-uninstall" && { log_info "K3s uninstall already completed, skipping."; return; }
    log_step "Running K3s Uninstall Scripts"

    if ${ROLLBACK_SERVER}; then
        if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
            log_info "Running k3s-uninstall.sh (server) ..."
            run_ok /usr/local/bin/k3s-uninstall.sh
            log_ok "K3s server uninstalled"
        else
            log_skip "k3s-uninstall.sh"
        fi
    fi

    if ${ROLLBACK_AGENT}; then
        if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
            log_info "Running k3s-agent-uninstall.sh ..."
            run_ok /usr/local/bin/k3s-agent-uninstall.sh
            log_ok "K3s agent uninstalled"
        else
            log_skip "k3s-agent-uninstall.sh"
        fi
    fi
    mark_done "k3s-uninstall"
}

# =============================================================================
# 3. Remove Helm-deployed resources (best-effort before removing binaries)
# =============================================================================
remove_helm_releases() {
    step_done "helm-releases" && { log_info "Helm releases already removed, skipping."; return; }
    log_step "Removing Helm Releases"

    local kc="/etc/rancher/k3s/k3s.yaml"
    if ! command -v helm &>/dev/null || [[ ! -f "${kc}" ]]; then
        log_skip "helm releases (helm or kubeconfig not found)"
        return
    fi

    export KUBECONFIG="${kc}"

    for release in cilium cert-manager; do
        local ns="kube-system"
        [[ "${release}" == "cert-manager" ]] && ns="cert-manager"

        if helm status "${release}" -n "${ns}" &>/dev/null 2>&1; then
            log_info "Helm uninstall: ${release} (namespace: ${ns}) ..."
            run_ok helm uninstall "${release}" -n "${ns}" --wait --timeout 2m
            log_ok "${release} removed"
        else
            log_skip "helm release: ${release}"
        fi
    done
    mark_done "helm-releases"
}

# =============================================================================
# 4. Tear down WireGuard and Cilium network interfaces
# =============================================================================
remove_network_interfaces() {
    step_done "network-interfaces" && { log_info "Network interfaces already cleaned, skipping."; return; }
    log_step "Removing Network Interfaces"

    # WireGuard interface created by Cilium
    if ip link show cilium_wg0 &>/dev/null 2>&1; then
        log_info "Removing WireGuard interface cilium_wg0 ..."
        run_ok ip link set cilium_wg0 down
        run_ok ip link delete cilium_wg0 type wireguard
        log_ok "cilium_wg0 removed"
    else
        log_skip "cilium_wg0"
    fi

    # Other Cilium interfaces
    for iface in cilium_host cilium_net lxc0; do
        if ip link show "${iface}" &>/dev/null 2>&1; then
            log_info "Removing interface ${iface} ..."
            run_ok ip link set "${iface}" down
            run_ok ip link delete "${iface}" || true
            log_ok "${iface} removed"
        else
            log_skip "${iface}"
        fi
    done

    # Remove any remaining cilium_* or lxc* interfaces
    local cilium_ifaces
    cilium_ifaces=$(ip link show 2>/dev/null | grep -oP '(?<=\d: )(cilium_\S+|lxc\S+)(?=:)' || true)
    if [[ -n "${cilium_ifaces}" ]]; then
        log_info "Removing remaining Cilium/LXC interfaces..."
        while IFS= read -r iface; do
            [[ -z "${iface}" ]] && continue
            run_ok ip link set "${iface}" down
            run_ok ip link delete "${iface}" || true
            log_ok "Removed ${iface}"
        done <<< "${cilium_ifaces}"
    fi

    # Flush custom routes/rules left by Cilium
    log_info "Flushing Cilium IP rules and routes..."
    run_ok ip rule del table 201 2>/dev/null || true
    run_ok ip rule del table 202 2>/dev/null || true
    run_ok ip route flush table 201 2>/dev/null || true
    run_ok ip route flush table 202 2>/dev/null || true
    log_ok "IP rules/routes flushed"
    mark_done "network-interfaces"
}

# =============================================================================
# 5. Remove CNI configuration and plugin files
# =============================================================================
remove_cni_config() {
    step_done "cni-config" && { log_info "CNI config already removed, skipping."; return; }
    log_step "Removing CNI Configuration"

    local cni_dirs=(
        /etc/cni
        /opt/cni
        /var/lib/cni
        /run/cilium
        /var/run/cilium
    )

    for dir in "${cni_dirs[@]}"; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing ${dir} ..."
            run_ok rm -rf "${dir}"
            log_ok "${dir} removed"
        else
            log_skip "${dir}"
        fi
    done

    # CNI config files that may land in other locations
    for f in /etc/cni/net.d/05-cilium.conf \
              /etc/cni/net.d/10-flannel.conflist; do
        [[ -f "${f}" ]] && { run_ok rm -f "${f}"; log_ok "Removed ${f}"; } || true
    done
    mark_done "cni-config"
}

# =============================================================================
# 6. Remove K3s data directories
# =============================================================================
remove_k3s_data() {
    step_done "k3s-data" && { log_info "K3s data directories already removed, skipping."; return; }
    log_step "Removing K3s Data Directories"

    local k3s_dirs=(
        /var/lib/rancher
        /var/lib/kubelet
        /etc/rancher
        /var/lib/etcd
        /var/log/pods
        /var/log/containers
    )

    for dir in "${k3s_dirs[@]}"; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing ${dir} ..."
            run_ok rm -rf "${dir}"
            log_ok "${dir} removed"
        else
            log_skip "${dir}"
        fi
    done

    # Kubeconfig files
    for kc in /root/.kube/config /home/ubuntu/.kube/config; do
        if [[ -f "${kc}" ]]; then
            run_ok rm -f "${kc}"
            log_ok "Removed kubeconfig: ${kc}"
        fi
    done
    run_ok rmdir /root/.kube         2>/dev/null || true
    run_ok rmdir /home/ubuntu/.kube  2>/dev/null || true
    mark_done "k3s-data"
}

# =============================================================================
# 7. Remove installed binaries
# =============================================================================
remove_binaries() {
    step_done "binaries" && { log_info "Binaries already removed, skipping."; return; }
    log_step "Removing Installed Binaries"

    # Binaries we placed from the bundle
    for bin in "${INSTALLED_BINS[@]}"; do
        if [[ -f "${bin}" ]]; then
            run_ok rm -f "${bin}"
            log_ok "Removed ${bin}"
        else
            log_skip "${bin}"
        fi
    done

    # K3s-managed symlinks (the official uninstall may have already removed these)
    for link in "${K3S_SYMLINKS[@]}"; do
        if [[ -L "${link}" ]] || [[ -f "${link}" ]]; then
            run_ok rm -f "${link}"
            log_ok "Removed ${link}"
        fi
    done

    # Kill-all and uninstall helper scripts placed by K3s installer
    for script in /usr/local/bin/k3s-killall.sh \
                  /usr/local/bin/k3s-uninstall.sh \
                  /usr/local/bin/k3s-agent-uninstall.sh; do
        [[ -f "${script}" ]] && { run_ok rm -f "${script}"; log_ok "Removed ${script}"; } || true
    done
    mark_done "binaries"
}

# =============================================================================
# 8. Remove systemd service files
# =============================================================================
remove_service_files() {
    step_done "service-files" && { log_info "Service files already removed, skipping."; return; }
    log_step "Removing systemd Service Files"

    local unit_dirs=(/etc/systemd/system /usr/lib/systemd/system /usr/local/lib/systemd/system)

    for dir in "${unit_dirs[@]}"; do
        [[ -d "${dir}" ]] || continue
        for unit in "${dir}"/k3s*.service "${dir}"/k3s*.env; do
            [[ -f "${unit}" ]] || continue
            run_ok rm -f "${unit}"
            log_ok "Removed ${unit}"
        done
    done

    # Remove drop-in directories
    for drop in /etc/systemd/system/k3s.service.d \
                /etc/systemd/system/k3s-agent.service.d; do
        [[ -d "${drop}" ]] && { run_ok rm -rf "${drop}"; log_ok "Removed ${drop}"; } || true
    done

    run_ok systemctl daemon-reload 2>/dev/null || true
    log_ok "systemd daemon reloaded"
    mark_done "service-files"
}

# =============================================================================
# 9. Revert sysctl changes (if --prepare or --all)
# =============================================================================
revert_sysctl() {
    ${ROLLBACK_PREPARE} || return 0
    step_done "sysctl" && { log_info "sysctl already reverted, skipping."; return; }
    log_step "Reverting sysctl Configuration"

    local sysctl_file="/etc/sysctl.d/99-k3s-cilium.conf"
    if [[ -f "${sysctl_file}" ]]; then
        run_ok rm -f "${sysctl_file}"
        log_ok "Removed ${sysctl_file}"
        run_ok sysctl --system &>/dev/null || true
        log_ok "sysctl settings reloaded"
    else
        log_skip "${sysctl_file}"
    fi

    # Also check the bundle-placed copy
    local bundle_sysctl="/opt/offline-bundle/manifests/99-k3s-cilium.conf"
    if [[ -f "${bundle_sysctl}" ]]; then
        run_ok rm -f "${bundle_sysctl}"
        log_ok "Removed bundle sysctl copy"
    fi
    mark_done "sysctl"
}

# =============================================================================
# 10. Revert kernel module load-on-boot config (if --prepare or --all)
# =============================================================================
revert_kernel_modules() {
    ${ROLLBACK_PREPARE} || return 0
    step_done "kernel-modules" && { log_info "Kernel module config already reverted, skipping."; return; }
    log_step "Reverting Kernel Module Configuration"

    local modfile="/etc/modules-load.d/k3s-cilium.conf"
    if [[ -f "${modfile}" ]]; then
        run_ok rm -f "${modfile}"
        log_ok "Removed ${modfile}"
    else
        log_skip "${modfile}"
    fi

    # Re-enable swap if it was disabled by prepare-node.sh
    # (only attempt if fstab has a commented swap line we can uncomment)
    if grep -q "^#.*swap" /etc/fstab 2>/dev/null; then
        log_info "Re-enabling swap in /etc/fstab ..."
        run_ok sed -i 's/^#\(.*swap.*\)/\1/' /etc/fstab
        log_warn "Swap re-enabled in fstab — reboot required to take effect"
    fi
    mark_done "kernel-modules"
}

# =============================================================================
# 11. Remove iptables rules left by K3s / Cilium
# =============================================================================
flush_iptables() {
    step_done "iptables" && { log_info "iptables already flushed, skipping."; return; }
    log_step "Flushing iptables Rules"

    if ! command -v iptables &>/dev/null; then
        log_skip "iptables not found"
        return
    fi

    # K3s creates a k3s-forward chain; Cilium creates CILIUM_* chains
    local chains_to_flush=(
        CILIUM_FORWARD CILIUM_INPUT CILIUM_OUTPUT
        CILIUM_POST_nat CILIUM_PRE_nat CILIUM_MANGLE_FORWARD
        KUBE-SERVICES KUBE-FORWARD KUBE-NODEPORTS
    )

    for table in filter nat mangle; do
        # Flush and delete K3s/Cilium chains
        iptables -t "${table}" -S 2>/dev/null | grep -E 'CILIUM_|k3s-' | awk '{print $2}' \
            | sort -u | while IFS= read -r chain; do
                iptables -t "${table}" -F "${chain}" 2>/dev/null || true
                iptables -t "${table}" -X "${chain}" 2>/dev/null || true
                log_debug "Flushed iptables chain: ${table}/${chain}"
            done
    done

    log_ok "iptables chains flushed"

    # ip6tables
    if command -v ip6tables &>/dev/null; then
        for table in filter nat mangle; do
            ip6tables -t "${table}" -S 2>/dev/null | grep -E 'CILIUM_|k3s-' | awk '{print $2}' \
                | sort -u | while IFS= read -r chain; do
                    ip6tables -t "${table}" -F "${chain}" 2>/dev/null || true
                    ip6tables -t "${table}" -X "${chain}" 2>/dev/null || true
                done
        done
        log_ok "ip6tables chains flushed"
    fi
    mark_done "iptables"
}

# =============================================================================
# 12. Remove etcd service, binaries, data, and config  (--etcd or --all)
# =============================================================================
remove_etcd() {
    ${ROLLBACK_ETCD} || return 0
    step_done "etcd-rollback" && { log_info "etcd already removed, skipping."; return; }
    log_step "Removing etcd"

    # Stop and disable service
    if systemctl is-active --quiet etcd 2>/dev/null; then
        log_info "Stopping etcd service..."
        run_ok systemctl stop etcd
        log_ok "etcd stopped"
    fi
    if systemctl is-enabled --quiet etcd 2>/dev/null; then
        run_ok systemctl disable etcd
    fi

    # Remove systemd unit
    if [[ -f /etc/systemd/system/etcd.service ]]; then
        run_ok rm -f /etc/systemd/system/etcd.service
        log_ok "Removed /etc/systemd/system/etcd.service"
    fi
    run_ok systemctl daemon-reload 2>/dev/null || true

    # Remove binaries
    for bin in /usr/local/bin/etcd /usr/local/bin/etcdctl; do
        if [[ -f "${bin}" ]]; then
            run_ok rm -f "${bin}"
            log_ok "Removed ${bin}"
        else
            log_skip "${bin}"
        fi
    done

    # Remove data and config directories
    for dir in /var/lib/etcd /etc/etcd; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing ${dir} ..."
            run_ok rm -rf "${dir}"
            log_ok "Removed ${dir}"
        else
            log_skip "${dir}"
        fi
    done

    # Remove etcd system user
    if id etcd &>/dev/null 2>&1; then
        run_ok userdel etcd 2>/dev/null || true
        log_ok "Removed system user 'etcd'"
    fi

    # Remove etcd step and connection files
    for f in "${LOG_DIR}/.etcd-steps" "${LOG_DIR}/etcd-connection.txt"; do
        [[ -f "${f}" ]] && { run_ok rm -f "${f}"; log_ok "Removed ${f}"; } || true
    done

    mark_done "etcd-rollback"
    log_ok "etcd fully removed"
}

# =============================================================================
# 13. Remove KUBECONFIG from shell config files  (--server or --all)
# =============================================================================
remove_kubectl_env() {
    ${ROLLBACK_SERVER} || return 0
    step_done "kubectl-env-rollback" && { log_info "kubectl env already cleaned, skipping."; return; }
    log_step "Removing KUBECONFIG from Shell Configuration"

    # Remove from profile.d (system-wide)
    if [[ -f /etc/profile.d/k3s-kubectl.sh ]]; then
        run_ok rm -f /etc/profile.d/k3s-kubectl.sh
        log_ok "Removed /etc/profile.d/k3s-kubectl.sh"
    else
        log_skip "/etc/profile.d/k3s-kubectl.sh"
    fi

    # Remove from /etc/environment
    if grep -q "KUBECONFIG=" /etc/environment 2>/dev/null; then
        run_ok sed -i '/^KUBECONFIG=/d' /etc/environment
        log_ok "Removed KUBECONFIG from /etc/environment"
    fi

    # Remove from user rc files
    for rcfile in /root/.bashrc /root/.profile \
                  /home/ubuntu/.bashrc /home/ubuntu/.profile \
                  /home/ubuntu/.bash_profile; do
        if [[ -f "${rcfile}" ]] && grep -q "KUBECONFIG=" "${rcfile}" 2>/dev/null; then
            run_ok sed -i '/export KUBECONFIG=/d' "${rcfile}"
            log_ok "Removed KUBECONFIG from ${rcfile}"
        fi
    done

    mark_done "kubectl-env-rollback"
}

# =============================================================================
# 14. Clean up step-tracking and log files
# =============================================================================
cleanup_tracking() {
    log_step "Removing Step-Tracking Files"

    # Always remove the rollback's own step file so re-runs are not skipped
    local step_files=("${STEP_FILE}")

    # Only remove prepare-steps when --prepare or --all was given
    ${ROLLBACK_PREPARE} && step_files+=("${LOG_DIR}/.prepare-steps")

    # Remove server step file when rolling back the server
    ${ROLLBACK_SERVER} && step_files+=(
        "${LOG_DIR}/.server-steps"
        "${LOG_DIR}/.cilium-steps"          # Cilium runs on server context
        "${LOG_DIR}/node-token.txt"
        "${LOG_DIR}/cilium-values-runtime.yaml"
    )

    # Remove agent step file when rolling back an agent
    ${ROLLBACK_AGENT} && step_files+=("${LOG_DIR}/.agent-steps")

    for f in "${step_files[@]}"; do
        if [[ -f "${f}" ]]; then
            run_ok rm -f "${f}"
            log_ok "Removed ${f}"
        fi
    done

    # --all: wipe the entire log directory for a fully clean slate
    if ${ROLLBACK_LOGS}; then
        log_info "Wiping log directory for clean slate: ${LOG_DIR}"
        # Print final message BEFORE we delete the log file itself
        log_info "Log directory will be removed. Goodbye, ${LOG_FILE}."
        run_ok rm -rf "${LOG_DIR}"
        echo -e "${GREEN}  ✔${NC} ${LOG_DIR} removed — node is at clean slate"
    else
        log_info "Rollback log preserved at: ${LOG_FILE}"
    fi
}

# =============================================================================
# 13. Final system state report
# =============================================================================
print_final_report() {
    log_step "Post-Rollback System State"

    local sep="─────────────────────────────────────────"

    echo "" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}  Services${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"

    for svc in k3s k3s-agent; do
        local state
        state=$(systemctl is-active "${svc}" 2>/dev/null || echo "not-found")
        echo "  ${svc}: ${state}" | tee -a "${LOG_FILE}"
    done

    echo "" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}  Binaries${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"

    for bin in /usr/local/bin/k3s /usr/local/bin/helm \
               /usr/local/bin/kubectl /usr/local/bin/cilium; do
        if [[ -f "${bin}" ]]; then
            echo -e "  ${YELLOW}STILL PRESENT${NC}: ${bin}" | tee -a "${LOG_FILE}"
        else
            echo -e "  ${GREEN}removed${NC}: ${bin}" | tee -a "${LOG_FILE}"
        fi
    done

    echo "" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}  Directories${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"

    for dir in /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni; do
        if [[ -d "${dir}" ]]; then
            echo -e "  ${YELLOW}STILL PRESENT${NC}: ${dir}" | tee -a "${LOG_FILE}"
        else
            echo -e "  ${GREEN}removed${NC}: ${dir}" | tee -a "${LOG_FILE}"
        fi
    done

    echo "" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}  Network Interfaces${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BOLD}${sep}${NC}" | tee -a "${LOG_FILE}"

    local cilium_ifaces
    cilium_ifaces=$(ip link show 2>/dev/null | grep -oP '(?<=\d: )(cilium_\S+|lxc\S+)(?=:)' || true)
    if [[ -n "${cilium_ifaces}" ]]; then
        echo -e "  ${YELLOW}REMAINING Cilium interfaces:${NC}" | tee -a "${LOG_FILE}"
        echo "${cilium_ifaces}" | while IFS= read -r iface; do
            echo "    ${iface}" | tee -a "${LOG_FILE}"
        done
    else
        echo -e "  ${GREEN}No Cilium/WireGuard interfaces remain${NC}" | tee -a "${LOG_FILE}"
    fi

    echo "" | tee -a "${LOG_FILE}"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${RED}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │           K3s + Cilium Rollback               │"
    echo "  │       Restore Node to Pre-Install State       │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    log_info "Rollback scope — server=${ROLLBACK_SERVER}  agent=${ROLLBACK_AGENT}  prepare=${ROLLBACK_PREPARE}  etcd=${ROLLBACK_ETCD}"
    ${DRY_RUN} && log_warn "DRY-RUN mode — no changes will be made"

    confirm_rollback

    # Execute rollback steps in safe order
    stop_k3s_services           # 1. Stop services first
    remove_helm_releases        # 2. Uninstall Helm releases while API is still up (best-effort)
    run_k3s_uninstall           # 3. Official K3s uninstall scripts (removes most things)
    remove_network_interfaces   # 4. WireGuard / Cilium interfaces
    flush_iptables              # 5. Clean iptables chains
    remove_cni_config           # 6. CNI config files
    remove_k3s_data             # 7. Data directories
    remove_binaries             # 8. Binaries we placed
    remove_service_files        # 9. systemd units
    revert_sysctl               # 10. sysctl config (--prepare only)
    revert_kernel_modules       # 11. Kernel module config (--prepare only)
    remove_etcd                 # 12. etcd service + data (--etcd/--all only)
    remove_kubectl_env          # 13. KUBECONFIG from shell configs (--server/--all)
    cleanup_tracking            # 14. Step files (+ log dir on --all)

    print_final_report          # Show what remains

    echo ""
    log_ok "Rollback complete. Log: ${LOG_FILE}"
    log_info ""
    log_warn "A reboot is recommended to clear remaining kernel state (WireGuard, eBPF maps)."
    log_info "  sudo reboot"
}

main "$@"
