#!/usr/bin/env bash
# =============================================================================
# install-k3s-agent.sh — Join a worker node to the K3s cluster (offline)
#
# Run AFTER install-k3s-server.sh on the control plane and prepare-node.sh
# on this worker node.
#
# Usage: sudo ./install-k3s-agent.sh --server-ip <IP> --token <TOKEN> --node-ip <IP> [--node-name NAME]
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/k3s-agent-install.log"
DEBUG=false
DRY_RUN=false

# Defaults
BUNDLE_PATH="/opt/offline-bundle"
SERVER_IP=""
K3S_TOKEN=""
NODE_IP=""
NODE_NAME=""    # K3s node name — must be unique across the cluster

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
STEP_FILE="${LOG_DIR}/.agent-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}install-k3s-agent.sh${NC} — Join a worker node to the K3s cluster (offline)

${BOLD}USAGE${NC}
  sudo $0 --server-ip <IP> --token <TOKEN> [--node-ip <IP>] [OPTIONS]

${BOLD}REQUIRED${NC}
  --server-ip IP   Control plane IP address
  --token TOKEN    Node join token (from: sudo cat /var/lib/rancher/k3s/server/node-token)

${BOLD}OPTIONS${NC}
  --node-ip IP         This agent node's IP     (default: auto-detected)
  --node-name NAME     Unique K3s node name     (default: hostname; auto-suffixed if duplicate)
  --bundle-path PATH   Offline bundle path       (default: ${BUNDLE_PATH})
  --debug              Enable debug output
  --dry-run            Print commands without executing
  -h, --help           Show this help

${BOLD}EXAMPLE${NC}
  sudo $0 --server-ip 192.168.1.10 --token 'K10xxx::server:yyy' --node-ip 192.168.1.20
  sudo $0 --server-ip 192.168.1.10 --token 'K10xxx::server:yyy' --node-name worker-01
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-ip)   SERVER_IP="${2:?--server-ip requires a value}"; shift 2 ;;
        --token)       K3S_TOKEN="${2:?--token requires a value}"; shift 2 ;;
        --node-ip)     NODE_IP="${2:?--node-ip requires a value}"; shift 2 ;;
        --node-name)   NODE_NAME="${2:?--node-name requires a value}"; shift 2 ;;
        --bundle-path) BUNDLE_PATH="${2:?--bundle-path requires a value}"; shift 2 ;;
        --debug)       DEBUG=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
[[ -n "${SERVER_IP}" ]]  || { log_error "--server-ip is required"; usage; exit 1; }
[[ -n "${K3S_TOKEN}" ]]  || { log_error "--token is required"; usage; exit 1; }

# Auto-detect node IP if not provided
if [[ -z "${NODE_IP}" ]]; then
    NODE_IP="$(ip -4 route get "${SERVER_IP}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1 || true)"
    [[ -n "${NODE_IP}" ]] || NODE_IP="$(hostname -I | awk '{print $1}')"
    log_info "Auto-detected node IP: ${NODE_IP}"
fi

# Default node name to hostname if not explicitly provided
if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME="$(hostname)"
fi

# =============================================================================
# 1. Bundle validation
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

    [[ "${missing}" -eq 0 ]] || { log_error "Bundle incomplete."; exit 1; }
    log_ok "Bundle verified"
}

# =============================================================================
# 2. Idempotency — detect existing agent
# =============================================================================
check_existing_agent() {
    log_step "Checking for Existing K3s Agent"

    if systemctl is-active --quiet k3s-agent 2>/dev/null; then
        log_warn "k3s-agent is already running on this node."
        # Verify it's connected to the right server
        local conf="/etc/rancher/k3s/config.yaml"
        if [[ -f "${conf}" ]] && grep -q "${SERVER_IP}" "${conf}" 2>/dev/null; then
            log_ok "Agent already connected to ${SERVER_IP} — nothing to do."
            SKIP_INSTALL=true
        else
            log_warn "Agent running but server mismatch. Run rollback.sh first."
            SKIP_INSTALL=true
        fi
    else
        SKIP_INSTALL=false
        log_ok "No running k3s-agent found — proceeding with install"
    fi
}

# =============================================================================
# 3. Verify connectivity to control plane
# =============================================================================
verify_connectivity() {
    log_step "Verifying Connectivity to Control Plane (${SERVER_IP})"

    local ping_ok=false

    # --- Layer 3: Ping ---
    if ping -c 2 -W 3 "${SERVER_IP}" &>/dev/null; then
        log_ok "Ping to ${SERVER_IP} OK"
        ping_ok=true
    else
        log_warn "Cannot ping ${SERVER_IP} — check network routing"
    fi

    # --- Layer 4: TCP port 6443 reachability (no TLS) ---
    local tcp_ok=false
    if timeout 5 bash -c ">/dev/tcp/${SERVER_IP}/6443" 2>/dev/null; then
        log_ok "TCP port 6443 reachable on ${SERVER_IP}"
        tcp_ok=true
    else
        log_warn "TCP port 6443 not reachable — checking ufw/firewall on server node:"
        log_warn "  sudo ufw allow 6443/tcp"
        log_warn "  sudo ufw allow from ${NODE_IP:-any} to any port 6443"
    fi

    # --- Layer 7: K3s /healthz with retries ---
    local api_ok=false
    local retries=5
    local wait_s=5
    log_info "Checking K3s API health (up to $((retries * wait_s))s) ..."
    for ((i=1; i<=retries; i++)); do
        local resp
        resp="$(curl -sk --connect-timeout 5 "https://${SERVER_IP}:6443/healthz" 2>/dev/null || true)"
        if echo "${resp}" | grep -q "ok"; then
            log_ok "K3s API server healthy at https://${SERVER_IP}:6443"
            api_ok=true
            break
        fi
        log_debug "Attempt ${i}/${retries}: API response: ${resp:-<no response>}"
        [[ ${i} -lt ${retries} ]] && sleep "${wait_s}"
    done

    # --- Decision ---
    if ${api_ok}; then
        return 0
    fi

    if ${tcp_ok}; then
        # Port is open but /healthz not returning "ok" yet.
        # K3s API is up (TCP works); health delay is normal during airgap init.
        log_warn "K3s API port is open but /healthz not yet returning 'ok'"
        log_warn "This is normal while K3s loads airgap images — proceeding"
        return 0
    fi

    if ${ping_ok}; then
        log_error "Network is reachable (ping OK) but port 6443 is blocked."
        log_error "On the CONTROL PLANE node, run:"
        log_error "  sudo ufw allow 6443/tcp && sudo ufw reload"
        log_error "  # OR if ufw is inactive, check: iptables -L INPUT -n | grep 6443"
        log_error "Then re-run this script."
    else
        log_error "Cannot reach ${SERVER_IP} at all — verify network connectivity."
    fi

    exit 1
}

# =============================================================================
# 4. Check for node name conflict on the cluster
# =============================================================================
check_node_name_conflict() {
    log_step "Checking Node Name Uniqueness (name: ${NODE_NAME})"

    # Try to list existing nodes via the K3s API (unauthenticated /healthz works,
    # but /api/v1/nodes needs a valid kubeconfig or service account token).
    # We use the node-token which is a valid bearer token for the API.
    local existing_nodes=""
    existing_nodes="$(curl -sk --connect-timeout 5 \
        -H "Authorization: Bearer ${K3S_TOKEN}" \
        "https://${SERVER_IP}:6443/api/v1/nodes" 2>/dev/null \
        | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' || true)"

    if [[ -z "${existing_nodes}" ]]; then
        log_warn "Could not query cluster node list — skipping conflict check"
        log_warn "If node registration hangs, re-run with: --node-name <unique-name>"
        log_ok "Proceeding with node name: ${NODE_NAME}"
        return
    fi

    log_debug "Existing nodes: $(echo "${existing_nodes}" | tr '\n' ' ')"

    if echo "${existing_nodes}" | grep -qx "${NODE_NAME}"; then
        local suffix; suffix="$(echo "${NODE_IP}" | cut -d. -f4)"
        local new_name="${NODE_NAME}-${suffix}"
        log_warn "⚠  Node name '${NODE_NAME}' already exists in the cluster!"
        log_warn "   This is likely because both nodes share the same hostname."
        log_warn "   Auto-renaming this node to: ${new_name}"
        log_warn "   To set a custom name, re-run with: --node-name <unique-name>"
        NODE_NAME="${new_name}"
    fi

    log_ok "Node name confirmed: ${NODE_NAME}"
}

# =============================================================================
# 5. Copy K3s artifacts from bundle
# =============================================================================
prepare_k3s_files() {
    # Check if already done AND files actually exist
    if step_done "agent-k3s-files" && [[ -f /usr/local/bin/k3s ]]; then
        log_info "K3s files already prepared, skipping."
        return
    fi

    # If step marker exists but files are missing, log warning and retry
    if step_done "agent-k3s-files"; then
        log_warn "Step marker exists but k3s binary missing — retrying file preparation..."
        sed -i '/^agent-k3s-files$/d' "${STEP_FILE}"
    fi

    log_step "Preparing K3s Files from Bundle"

    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    # K3s binary
    run cp "${BUNDLE_PATH}/binaries/k3s" /usr/local/bin/k3s
    run chmod +x /usr/local/bin/k3s
    log_ok "k3s binary → /usr/local/bin/k3s"

    # Airgap images (K3s looks here at startup)
    run mkdir -p /var/lib/rancher/k3s/agent/images
    local airgap_img="${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
    if [[ -f "${airgap_img}" ]]; then
        run cp "${airgap_img}" /var/lib/rancher/k3s/agent/images/
        log_ok "Airgap images → /var/lib/rancher/k3s/agent/images/"
    fi

    # Install kubectl and crictl for convenience on workers
    for bin in kubectl crictl; do
        local src="${BUNDLE_PATH}/binaries/${bin}"
        [[ -f "${src}" ]] || continue
        run cp "${src}" "/usr/local/bin/${bin}"
        run chmod +x "/usr/local/bin/${bin}"
        log_ok "${bin} → /usr/local/bin/"
    done

    mark_done "agent-k3s-files"
}

# =============================================================================
# 6. Install K3s agent
# =============================================================================
install_k3s_agent() {
    if [[ "${SKIP_INSTALL:-false}" == "true" ]]; then
        log_info "K3s agent already running — skipping install."
        return
    fi

    step_done "agent-install" && { log_info "K3s agent install already completed, skipping."; return; }
    log_step "Installing K3s Agent"

    log_info "Server URL  : https://${SERVER_IP}:6443"
    log_info "Node IP     : ${NODE_IP}"
    log_info "Node Name   : ${NODE_NAME}"

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_BIN_DIR=/usr/local/bin \
    INSTALL_K3S_EXEC="agent \
        --server https://${SERVER_IP}:6443 \
        --token ${K3S_TOKEN} \
        --node-ip ${NODE_IP} \
        --node-name ${NODE_NAME}" \
    K3S_URL="https://${SERVER_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    bash "${BUNDLE_PATH}/binaries/install.sh" 2>&1 | tee -a "${LOG_FILE}"

    mark_done "agent-install"
    log_ok "K3s agent installation complete"
}

# =============================================================================
# 7. Wait for agent to join
# =============================================================================
wait_for_agent() {
    log_step "Waiting for k3s-agent Service to Start"

    # Give systemd a moment to start the service before polling
    sleep 5

    local timeout=180   # 3 min — airgap image loading takes time
    local elapsed=5
    local interval=5

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if systemctl is-active --quiet k3s-agent 2>/dev/null; then
            log_ok "k3s-agent is running (${elapsed}s)"
            break
        fi
        log_info "  Waiting for k3s-agent... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    if ! systemctl is-active --quiet k3s-agent 2>/dev/null; then
        # Check if it failed vs is still starting (activating state)
        local state; state="$(systemctl is-active k3s-agent 2>/dev/null || true)"
        if [[ "${state}" == "activating" ]]; then
            log_warn "k3s-agent still starting after ${timeout}s — this may be normal for airgap"
            log_warn "Check status: systemctl status k3s-agent"
        else
            log_error "k3s-agent did not start within ${timeout}s (state: ${state:-unknown})"
            log_error "Check: journalctl -u k3s-agent --no-pager -n 50"
            exit 1
        fi
    fi

    log_info ""
    log_info "Node join initiated. Verify from the CONTROL PLANE:"
    log_info "  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o wide"
    log_info ""
    log_warn "Node will show NotReady until Cilium is installed."
}

# =============================================================================
# 8. Load Cilium images into containerd on this node
# =============================================================================
load_cilium_images() {
    # Verify step marker AND that images actually exist in containerd
    if step_done "agent-cilium-images"; then
        local cilium_count
        # K3s containerd socket is at /run/k3s/containerd/containerd.sock
        cilium_count="$(ctr --address /run/k3s/containerd/containerd.sock \
            --namespace k8s.io images list 2>/dev/null | grep -c cilium || true)"
        if [[ "${cilium_count}" -gt 0 ]]; then
            log_info "Cilium images already loaded (${cilium_count} images), skipping."
            return
        fi
        log_warn "Step marker exists but cilium images missing in containerd — retrying import..."
        sed -i '/^agent-cilium-images$/d' "${STEP_FILE}"
    fi

    log_step "Loading Cilium Images into containerd"

    # K3s embeds its own containerd whose socket is NOT the system default.
    # Always specify the K3s socket path to avoid hitting system containerd.
    local k3s_ctr_addr="/run/k3s/containerd/containerd.sock"

    if [[ ! -S "${k3s_ctr_addr}" ]]; then
        log_warn "K3s containerd socket not found at ${k3s_ctr_addr}"
        log_warn "k3s-agent may still be initialising — waiting 10s..."
        sleep 10
    fi

    local cilium_tar="${BUNDLE_PATH}/images/cilium-images.tar"
    local cm_tar="${BUNDLE_PATH}/images/cert-manager-images.tar"

    for tarfile in "${cilium_tar}" "${cm_tar}"; do
        [[ -f "${tarfile}" ]] || continue
        log_info "Importing $(basename "${tarfile}") ..."
        if run ctr --address "${k3s_ctr_addr}" \
                --namespace k8s.io images import "${tarfile}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_ok "$(basename "${tarfile}") imported"
        else
            log_error "Failed to import $(basename "${tarfile}")"
            log_error "Check: systemctl status k3s-agent"
            exit 1
        fi
    done

    # Confirm images are visible
    local loaded
    loaded="$(ctr --address "${k3s_ctr_addr}" --namespace k8s.io images list 2>/dev/null \
        | grep -E "cilium|hubble|certgen" | awk '{print "  " $1}' || true)"
    if [[ -n "${loaded}" ]]; then
        log_info "Loaded images:"
        echo "${loaded}" | tee -a "${LOG_FILE}"
    fi

    mark_done "agent-cilium-images"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │       K3s Worker Node Installation            │"
    echo "  │   Cilium + WireGuard — Offline Bundle         │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    verify_bundle
    check_existing_agent
    verify_connectivity
    check_node_name_conflict
    prepare_k3s_files
    install_k3s_agent
    wait_for_agent
    load_cilium_images

    echo ""
    log_ok "K3s agent installed and joined the cluster. Log: ${LOG_FILE}"
    log_info ""
    log_info "Next steps (run on CONTROL PLANE after ALL agents joined):"
    log_info "  sudo ./install-cilium.sh --server-ip ${SERVER_IP}"
}

main "$@"
