#!/usr/bin/env bash
# =============================================================================
# install-k3s-server.sh — Install K3s Control Plane (offline, Cilium-ready)
#
# Installs K3s with Flannel, kube-proxy and traefik disabled so Cilium
# can take over as CNI and eBPF kube-proxy replacement.
#
# Usage: sudo ./install-k3s-server.sh --node-ip <IP> [OPTIONS]
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/k3s-server-install.log"
DEBUG=false
DRY_RUN=false

# Defaults — bundle-compatible paths
BUNDLE_PATH="/opt/offline-bundle"
NODE_IP=""
CLUSTER_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_DNS="10.96.0.10"
KUBECONFIG_DEST="/etc/rancher/k3s/k3s.yaml"

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
STEP_FILE="${LOG_DIR}/.server-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}install-k3s-server.sh${NC} — Install K3s control plane (Cilium-ready, offline)

${BOLD}USAGE${NC}
  sudo $0 --node-ip <IP> [OPTIONS]

${BOLD}REQUIRED${NC}
  --node-ip IP         This node's IP address (advertised to cluster)

${BOLD}OPTIONS${NC}
  --bundle-path PATH   Path to extracted offline bundle  (default: ${BUNDLE_PATH})
  --cluster-cidr CIDR  Pod network CIDR                  (default: ${CLUSTER_CIDR})
  --service-cidr CIDR  Service network CIDR              (default: ${SERVICE_CIDR})
  --debug              Enable debug output
  --dry-run            Print commands without executing
  -h, --help           Show this help

${BOLD}EXAMPLE${NC}
  sudo $0 --node-ip 192.168.1.10
  sudo $0 --node-ip 192.168.1.10 --bundle-path /mnt/bundle
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-ip)      NODE_IP="${2:?--node-ip requires a value}"; shift 2 ;;
        --bundle-path)  BUNDLE_PATH="${2:?--bundle-path requires a value}"; shift 2 ;;
        --cluster-cidr) CLUSTER_CIDR="${2:?}"; shift 2 ;;
        --service-cidr) SERVICE_CIDR="${2:?}"; shift 2 ;;
        --debug)        DEBUG=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
[[ -n "${NODE_IP}" ]] || { log_error "--node-ip is required"; usage; exit 1; }

# =============================================================================
# 1. Offline bundle validation
# =============================================================================
verify_bundle() {
    log_step "Verifying Offline Bundle at ${BUNDLE_PATH}"

    [[ -d "${BUNDLE_PATH}" ]] || {
        log_error "Bundle not found: ${BUNDLE_PATH}"
        log_error "Extract with: sudo tar -xzf offline-bundle.tar.gz -C /opt/"
        exit 1
    }

    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    local required=(
        "${BUNDLE_PATH}/binaries/k3s"
        "${BUNDLE_PATH}/binaries/install.sh"
        "${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
    )

    local missing=0
    for f in "${required[@]}"; do
        [[ -f "${f}" ]] && log_ok "${f##*/}" || { log_error "MISSING: ${f}"; missing=$((missing+1)); }
    done

    [[ "${missing}" -eq 0 ]] || { log_error "Bundle incomplete. Run prepare-offline-bundle.sh again."; exit 1; }
    log_ok "Bundle verified"
}

# =============================================================================
# 2. Idempotency — detect existing installation
# =============================================================================
check_existing_install() {
    log_step "Checking for Existing K3s Installation"

    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_warn "K3s server is already running."
        log_warn "To reinstall, run rollback.sh first, then re-run this script."
        log_warn "Continuing with configuration verification..."
        SKIP_INSTALL=true
    else
        SKIP_INSTALL=false
        log_ok "No running K3s server found — proceeding with fresh install"
    fi

    if command -v k3s &>/dev/null; then
        log_info "k3s binary found: $(k3s --version 2>/dev/null | head -1)"
    fi
}

# =============================================================================
# 3. Copy K3s artifacts from bundle
# =============================================================================
prepare_k3s_files() {
    # Check if already done AND files actually exist
    if step_done "k3s-files" && [[ -f /usr/local/bin/k3s ]]; then
        log_info "K3s files already prepared, skipping."
        return
    fi

    # If step marker exists but files are missing, log warning and retry
    if step_done "k3s-files"; then
        log_warn "Step marker exists but k3s binary missing — retrying file preparation..."
        sed -i '/^k3s-files$/d' "${STEP_FILE}"
    fi

    log_step "Preparing K3s Files from Bundle"

    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    # Copy K3s binary
    run cp "${BUNDLE_PATH}/binaries/k3s" /usr/local/bin/k3s
    run chmod +x /usr/local/bin/k3s
    log_ok "k3s binary installed to /usr/local/bin/k3s"

    # Place airgap images where K3s expects them
    run mkdir -p /var/lib/rancher/k3s/agent/images
    local airgap_img="${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
    if [[ -f "${airgap_img}" ]]; then
        run cp "${airgap_img}" /var/lib/rancher/k3s/agent/images/
        log_ok "Airgap images copied to /var/lib/rancher/k3s/agent/images/"
    fi

    # Install kubectl, helm, cilium CLI
    for bin in kubectl helm cilium crictl; do
        local src="${BUNDLE_PATH}/binaries/${bin}"
        [[ -f "${src}" ]] || continue
        run cp "${src}" "/usr/local/bin/${bin}"
        run chmod +x "/usr/local/bin/${bin}"
        log_ok "${bin} installed to /usr/local/bin/"
    done

    mark_done "k3s-files"
}

# =============================================================================
# 4. Run K3s server installation
# =============================================================================
install_k3s_server() {
    if [[ "${SKIP_INSTALL:-false}" == "true" ]]; then
        log_info "K3s already running — skipping install."
        return
    fi

    step_done "k3s-server-install" && { log_info "K3s install already completed, skipping."; return; }
    log_step "Installing K3s Control Plane"

    log_info "Node IP        : ${NODE_IP}"
    log_info "Cluster CIDR   : ${CLUSTER_CIDR}"
    log_info "Service CIDR   : ${SERVICE_CIDR}"
    log_info "Cluster DNS    : ${CLUSTER_DNS}"
    log_info "Bundle path    : ${BUNDLE_PATH}"

    # Build the exec flags for Cilium-compatible K3s server:
    #   --flannel-backend=none      → Cilium is the CNI
    #   --disable-network-policy    → Cilium handles NetworkPolicy
    #   --disable-kube-proxy        → Cilium eBPF replaces kube-proxy
    #   --disable=traefik           → not needed for Cilium-only setup
    #   --disable=servicelb         → Cilium handles LB
    local k3s_exec_flags=(
        "server"
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
        "--disable=traefik"
        "--disable=servicelb"
        "--cluster-cidr=${CLUSTER_CIDR}"
        "--service-cidr=${SERVICE_CIDR}"
        "--cluster-dns=${CLUSTER_DNS}"
        "--node-ip=${NODE_IP}"
        "--tls-san=${NODE_IP}"
        "--write-kubeconfig-mode=644"
    )

    log_debug "K3s exec flags: ${k3s_exec_flags[*]}"

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_BIN_DIR=/usr/local/bin \
    INSTALL_K3S_EXEC="${k3s_exec_flags[*]}" \
    bash "${BUNDLE_PATH}/binaries/install.sh" 2>&1 | tee -a "${LOG_FILE}"

    mark_done "k3s-server-install"
    log_ok "K3s server installation complete"
}

# =============================================================================
# 5. Wait for K3s to be ready
# =============================================================================
wait_for_k3s() {
    log_step "Waiting for K3s API Server"

    # Give K3s a moment to start before polling — airgap image loading takes time
    log_info "  Giving K3s 15s to initialise..."
    sleep 15

    local timeout=300   # 5 min — airgap + etcd init can take >2 min
    local elapsed=15
    local interval=5
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Try to get nodes with kubectl — works if API is responsive
        # This is more reliable than /healthz which requires authentication
        if kubectl get nodes &>/dev/null; then
            log_ok "K3s API server is responsive (${elapsed}s)"
            return 0
        fi
        log_info "  Waiting for API server... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_error "K3s API server did not become responsive within ${timeout}s"
    log_error "Check service: systemctl status k3s"
    log_error "Check logs: journalctl -u k3s --no-pager -n 50"
    exit 1
}

# =============================================================================
# 6. Configure kubectl
# =============================================================================
configure_kubectl() {
    step_done "kubectl-config" && { log_info "kubectl already configured, skipping."; return; }
    log_step "Configuring kubectl Access"

    local kc="/etc/rancher/k3s/k3s.yaml"
    export KUBECONFIG="${kc}"

    # ── root ──────────────────────────────────────────────────────────────────
    mkdir -p /root/.kube
    run cp "${kc}" /root/.kube/config
    run chmod 600 /root/.kube/config

    # Persist KUBECONFIG for root's interactive + login shells
    for rcfile in /root/.bashrc /root/.profile; do
        if [[ -f "${rcfile}" ]] && ! grep -q "KUBECONFIG=" "${rcfile}" 2>/dev/null; then
            echo "export KUBECONFIG=${kc}" >> "${rcfile}"
            log_ok "KUBECONFIG added to ${rcfile}"
        fi
    done

    # ── ubuntu user ───────────────────────────────────────────────────────────
    if id ubuntu &>/dev/null; then
        local home_dir="/home/ubuntu"
        mkdir -p "${home_dir}/.kube"
        run cp "${kc}" "${home_dir}/.kube/config"
        run chown -R ubuntu:ubuntu "${home_dir}/.kube"
        run chmod 600 "${home_dir}/.kube/config"

        # Persist KUBECONFIG for non-login interactive shells (.bashrc)
        if ! grep -q "KUBECONFIG=" "${home_dir}/.bashrc" 2>/dev/null; then
            echo "export KUBECONFIG=${kc}" >> "${home_dir}/.bashrc"
            log_ok "KUBECONFIG added to ${home_dir}/.bashrc"
        fi

        # Persist for login shells (.profile / .bash_profile)
        for rcfile in "${home_dir}/.profile" "${home_dir}/.bash_profile"; do
            if [[ -f "${rcfile}" ]] && ! grep -q "KUBECONFIG=" "${rcfile}" 2>/dev/null; then
                echo "export KUBECONFIG=${kc}" >> "${rcfile}"
                log_ok "KUBECONFIG added to ${rcfile}"
            fi
        done
    fi

    # ── system-wide (all users + sudo sessions) ───────────────────────────────
    # /etc/profile.d/ is sourced for all login shells, including `sudo -i`
    cat > /etc/profile.d/k3s-kubectl.sh <<PROFILE
# K3s kubeconfig — set by install-k3s-server.sh
export KUBECONFIG=${kc}
PROFILE
    chmod 644 /etc/profile.d/k3s-kubectl.sh
    log_ok "KUBECONFIG set system-wide via /etc/profile.d/k3s-kubectl.sh"

    # /etc/environment is read by PAM (SSH, sudo, cron) — no 'export' needed
    if ! grep -q "KUBECONFIG=" /etc/environment 2>/dev/null; then
        echo "KUBECONFIG=${kc}" >> /etc/environment
        log_ok "KUBECONFIG added to /etc/environment (applies to sudo sessions)"
    fi

    log_ok "kubectl ready — works for all users without 'export KUBECONFIG=...'"
    log_info "  Regular user : kubectl get nodes"
    log_info "  As root/sudo : sudo kubectl get nodes"
    mark_done "kubectl-config"
}

# =============================================================================
# 7. Wait for node Ready
# =============================================================================
wait_for_node_ready() {
    log_step "Waiting for Control Plane Node to Become Ready"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    local timeout=180
    local elapsed=0
    local interval=10

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local status
        status="$(kubectl get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        if [[ "${status}" == "True" ]]; then
            log_ok "Node $(hostname) is Ready (${elapsed}s)"
            return 0
        fi
        log_info "  Node status: ${status:-Unknown} — waiting... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    # Node NotReady is expected until Cilium is installed — warn, don't fail
    log_warn "Node not Ready after ${timeout}s — this is normal until Cilium is installed"
    log_warn "Run install-cilium.sh after all nodes have joined"
}

# =============================================================================
# 8. Output node token
# =============================================================================
output_token() {
    log_step "Node Join Token (for agent nodes)"

    local token_file="/var/lib/rancher/k3s/server/node-token"
    local retries=0
    while [[ ! -f "${token_file}" && ${retries} -lt 30 ]]; do
        sleep 2
        retries=$((retries + 1))
    done

    if [[ -f "${token_file}" ]]; then
        local token; token="$(cat "${token_file}")"
        echo ""
        echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║           K3s Agent Join Information                   ║${NC}"
        echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${BOLD}Server URL:${NC}  https://${NODE_IP}:6443"
        echo -e "  ${BOLD}Token:${NC}"
        echo -e "  ${CYAN}${token}${NC}"
        echo ""
        echo -e "  ${BOLD}Agent install command:${NC}"
        echo -e "  ${YELLOW}sudo ./install-k3s-agent.sh \\${NC}"
        echo -e "  ${YELLOW}    --server-ip ${NODE_IP} \\${NC}"
        echo -e "  ${YELLOW}    --token '${token}'${NC}"
        echo ""

        # Save token to log dir for reference
        echo "${token}" > "${LOG_DIR}/node-token.txt"
        log_info "Token also saved to ${LOG_DIR}/node-token.txt"
    else
        log_warn "Token file not yet available at ${token_file}"
        log_warn "Retrieve manually: sudo cat ${token_file}"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │     K3s Control Plane Installation            │"
    echo "  │   Cilium + WireGuard — Offline Bundle         │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    verify_bundle
    check_existing_install
    prepare_k3s_files
    install_k3s_server
    wait_for_k3s
    configure_kubectl
    wait_for_node_ready
    output_token

    echo ""
    log_ok "K3s control plane installed. Log: ${LOG_FILE}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run prepare-node.sh + install-k3s-agent.sh on each worker"
    log_info "  2. Run install-cilium.sh on the control plane after all nodes joined"
    log_info "  3. Run validate-cluster.sh to verify the full stack"
}

main "$@"
