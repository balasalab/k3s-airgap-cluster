#!/usr/bin/env bash
# =============================================================================
# install-cilium.sh — Install Cilium CNI with WireGuard encryption (offline)
#
# Run on the CONTROL PLANE after all K3s nodes have joined the cluster.
# Reads all artifacts from the offline bundle.
#
# Usage: sudo ./install-cilium.sh --server-ip <CONTROL-PLANE-IP> [OPTIONS]
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/cilium-install.log"
DEBUG=false
DRY_RUN=false

# Defaults — must match prepare-offline-bundle.sh versions
BUNDLE_PATH="/opt/offline-bundle"
CILIUM_VERSION="1.19.1"
CERT_MANAGER_VERSION="v1.19.4"
SERVER_IP=""
NAMESPACE="kube-system"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

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
STEP_FILE="${LOG_DIR}/.cilium-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}install-cilium.sh${NC} — Install Cilium CNI + WireGuard encryption (offline)

${BOLD}USAGE${NC}
  sudo $0 --server-ip <IP> [OPTIONS]

${BOLD}REQUIRED${NC}
  --server-ip IP       Control plane IP (used as k8sServiceHost in Cilium values)

${BOLD}OPTIONS${NC}
  --bundle-path PATH   Offline bundle path           (default: ${BUNDLE_PATH})
  --cilium-version VER Cilium chart version           (default: ${CILIUM_VERSION})
  --kubeconfig PATH    Path to kubeconfig             (default: ${KUBECONFIG})
  --debug              Enable debug output
  --dry-run            Print commands without executing
  -h, --help           Show this help

${BOLD}EXAMPLE${NC}
  sudo $0 --server-ip 192.168.1.10
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-ip)      SERVER_IP="${2:?--server-ip requires a value}"; shift 2 ;;
        --bundle-path)    BUNDLE_PATH="${2:?}"; shift 2 ;;
        --cilium-version) CILIUM_VERSION="${2:?}"; shift 2 ;;
        --kubeconfig)     KUBECONFIG="${2:?}"; shift 2 ;;
        --debug)          DEBUG=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
[[ -n "${SERVER_IP}" ]] || { log_error "--server-ip is required"; usage; exit 1; }
export KUBECONFIG

# =============================================================================
# 1. Verify bundle + cluster prerequisites
# =============================================================================
verify_prerequisites() {
    log_step "Verifying Prerequisites"

    # Bundle dir
    [[ -d "${BUNDLE_PATH}" ]] || {
        log_error "Bundle not found: ${BUNDLE_PATH}"; exit 1
    }

    # Cilium chart
    local chart="${BUNDLE_PATH}/helm-charts/cilium-${CILIUM_VERSION}.tgz"
    [[ -f "${chart}" ]] && log_ok "Cilium chart: ${chart}" || {
        log_error "Cilium chart missing: ${chart}"; exit 1
    }

    # Cilium images tar
    local cilium_tar="${BUNDLE_PATH}/images/cilium-images.tar"
    [[ -f "${cilium_tar}" ]] && log_ok "cilium-images.tar" || {
        log_warn "cilium-images.tar not found — images must already be loaded"
    }

    # Helm binary
    command -v helm &>/dev/null && log_ok "helm: $(helm version --short 2>/dev/null)" || {
        log_error "helm not found — run prepare-node.sh first"; exit 1
    }

    # kubectl + cluster access
    command -v kubectl &>/dev/null || { log_error "kubectl not found"; exit 1; }
    kubectl cluster-info &>/dev/null 2>&1 && log_ok "Cluster API accessible" || {
        log_error "Cannot access cluster. Check KUBECONFIG: ${KUBECONFIG}"; exit 1
    }

    # K3s running
    systemctl is-active --quiet k3s && log_ok "k3s service running" || {
        log_error "k3s is not running. Install the control plane first."; exit 1
    }
}

# =============================================================================
# 2. Load Cilium images into containerd on control plane
# =============================================================================
load_images() {
    # K3s embeds its own containerd; always use the K3s socket, NOT /run/containerd/containerd.sock
    local k3s_ctr_addr="/run/k3s/containerd/containerd.sock"

    # Check if already done AND cilium images actually exist in containerd
    if step_done "cilium-images-loaded"; then
        local cilium_count
        cilium_count="$(ctr --address "${k3s_ctr_addr}" --namespace k8s.io images list \
            2>/dev/null | grep -c cilium || true)"
        if [[ ${cilium_count} -gt 0 ]]; then
            log_info "Cilium images already loaded (${cilium_count} images), skipping."
            return
        else
            log_warn "Step marker exists but cilium images missing in containerd — retrying load..."
            sed -i '/^cilium-images-loaded$/d' "${STEP_FILE}"
        fi
    fi

    log_step "Loading Container Images into containerd"

    local images_dir="${BUNDLE_PATH}/images"

    for tarfile in "${images_dir}/cilium-images.tar" "${images_dir}/cert-manager-images.tar"; do
        [[ -f "${tarfile}" ]] || continue
        log_info "Importing: $(basename "${tarfile}")"
        if run ctr --address "${k3s_ctr_addr}" \
                --namespace k8s.io images import "${tarfile}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_ok "$(basename "${tarfile}") imported"
        else
            log_error "Failed to import $(basename "${tarfile}") — check file format and containerd status"
            log_error "Verify K3s is running: systemctl status k3s"
            exit 1
        fi
    done

    # Show loaded Cilium images
    log_info "Loaded Cilium images:"
    ctr --address "${k3s_ctr_addr}" --namespace k8s.io images list 2>/dev/null \
        | grep -E "cilium|hubble|certgen" \
        | awk '{print "  " $1}' | tee -a "${LOG_FILE}" || true

    mark_done "cilium-images-loaded"
}

# =============================================================================
# 3. Patch cilium-values.yaml with actual control plane IP
# =============================================================================
prepare_values() {
    log_step "Preparing Cilium Helm Values"

    local src_values="${BUNDLE_PATH}/manifests/cilium-values.yaml"
    local runtime_values="${LOG_DIR}/cilium-values-runtime.yaml"

    [[ -f "${src_values}" ]] || {
        log_error "cilium-values.yaml not found at ${src_values}"
        exit 1
    }

    # Replace the placeholder with the actual server IP
    sed "s/CHANGE_ME_CONTROL_PLANE_IP/${SERVER_IP}/g" "${src_values}" > "${runtime_values}"

    # Verify the substitution worked
    if grep -q "CHANGE_ME_CONTROL_PLANE_IP" "${runtime_values}"; then
        log_error "Placeholder replacement failed in ${runtime_values}"
        exit 1
    fi

    log_ok "Values file prepared: ${runtime_values}"
    log_info "  k8sServiceHost: ${SERVER_IP}"
    log_info "  encryption.type: wireguard"
    log_info "  kubeProxyReplacement: true"
    log_info "  image.pullPolicy: IfNotPresent (offline images by tag)"

    CILIUM_VALUES_FILE="${runtime_values}"
}

# =============================================================================
# 4. Clean up stuck namespaces (from failed previous uninstalls)
# =============================================================================
cleanup_stuck_namespaces() {
    log_step "Cleaning Up Stuck Cilium Namespaces"

    for ns in cilium-secrets cilium; do
        if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
            local phase; phase="$(kubectl get ns "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
            if [[ "${phase}" == "Terminating" ]]; then
                log_warn "Namespace ${ns} is stuck in Terminating state — removing finalizers..."
                # Export namespace, clear finalizers, and force delete
                kubectl get namespace "${ns}" -o json 2>/dev/null \
                    | sed 's/"finalizers": \[.*\]/"finalizers": []/' \
                    | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null 2>&1 || true
                log_ok "Finalizers removed for ${ns}"
            fi
        fi
    done
}

# =============================================================================
# 5. Check if Cilium already installed
# =============================================================================
check_existing_cilium() {
    log_step "Checking for Existing Cilium Installation"

    if helm status cilium -n "${NAMESPACE}" &>/dev/null 2>&1; then
        local current_ver
        current_ver="$(helm list -n "${NAMESPACE}" -o json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); \
              [print(r['chart']) for r in d if r['name']=='cilium']" 2>/dev/null || true)"
        log_warn "Cilium is already installed: ${current_ver}"
        log_info "Running helm upgrade instead of install..."
        CILIUM_UPGRADE=true
    else
        CILIUM_UPGRADE=false
        log_ok "No existing Cilium found — fresh install"
    fi
}

# =============================================================================
# 6. Install / upgrade Cilium via Helm
# =============================================================================
deploy_cilium() {
    # Check if already done AND cilium deployment actually exists
    if step_done "cilium-helm-deploy"; then
        local cilium_pods
        cilium_pods="$(kubectl get deployment -n kube-system cilium-operator 2>/dev/null || true)"
        if [[ -n "${cilium_pods}" ]]; then
            log_info "Cilium Helm deploy already completed, skipping."
            return
        else
            log_warn "Step marker exists but cilium deployment missing — retrying helm install..."
            sed -i '/^cilium-helm-deploy$/d' "${STEP_FILE}"
        fi
    fi

    log_step "Deploying Cilium ${CILIUM_VERSION} via Helm"

    local chart="${BUNDLE_PATH}/helm-charts/cilium-${CILIUM_VERSION}.tgz"
    local helm_cmd="install"
    [[ "${CILIUM_UPGRADE:-false}" == "true" ]] && helm_cmd="upgrade"

    log_info "Helm ${helm_cmd}: cilium from ${chart}"

    # Note: persistentKeepalive must be a string (e.g. "25s"), not a number.
    # Cilium 1.19.1 Helm chart validates this as a duration string.
    # Use pullPolicy: IfNotPresent for offline mode to find images by tag (not digest).
    run helm "${helm_cmd}" cilium "${chart}" \
        --namespace "${NAMESPACE}" \
        --values "${CILIUM_VALUES_FILE}" \
        --set "k8sServiceHost=${SERVER_IP}" \
        --set "k8sServicePort=6443" \
        --set "encryption.wireguard.persistentKeepalive=25s" \
        --set "image.pullPolicy=IfNotPresent" \
        --wait \
        --timeout 10m \
        2>&1 | tee -a "${LOG_FILE}"

    mark_done "cilium-helm-deploy"
    log_ok "Cilium deployed successfully"
}

# =============================================================================
# 7. Wait for Cilium pods to be ready
# =============================================================================
wait_for_cilium() {
    log_step "Waiting for Cilium Pods to Become Ready"

    local timeout=300
    local elapsed=0
    local interval=10

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local total desired
        total="$(kubectl get daemonset cilium -n "${NAMESPACE}" \
            -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
        desired="$(kubectl get daemonset cilium -n "${NAMESPACE}" \
            -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"

        if [[ "${desired}" -gt 0 && "${total}" -eq "${desired}" ]]; then
            log_ok "Cilium: ${total}/${desired} pods Ready (${elapsed}s)"
            break
        fi

        log_info "  Cilium pods: ${total}/${desired} ready — waiting... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    # Check Cilium operator
    local op_ready
    op_ready="$(kubectl get deployment cilium-operator -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${op_ready}" -gt 0 ]] \
        && log_ok "Cilium operator: ${op_ready} replica(s) ready" \
        || log_warn "Cilium operator not ready yet"
}

# =============================================================================
# 8. Verify WireGuard interfaces
# =============================================================================
verify_wireguard() {
    log_step "Verifying WireGuard Encryption"

    # Give Cilium a moment to create the WireGuard interface
    sleep 5

    if ip link show cilium_wg0 &>/dev/null; then
        log_ok "WireGuard interface cilium_wg0 is present"
        log_info "WireGuard interface details:"
        ip link show cilium_wg0 | tee -a "${LOG_FILE}"

        if command -v wg &>/dev/null; then
            log_info "WireGuard peers:"
            wg show cilium_wg0 2>/dev/null | tee -a "${LOG_FILE}" || true
        fi
    else
        log_warn "cilium_wg0 not yet visible — may appear after pods schedule on multiple nodes"
        log_warn "WireGuard tunnels only form between nodes, not within a single node"
    fi

    # Check Cilium knows about encryption
    local cilium_pod
    cilium_pod="$(kubectl get pods -n "${NAMESPACE}" -l k8s-app=cilium \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -n "${cilium_pod}" ]]; then
        log_info "Checking Cilium encryption status on pod ${cilium_pod}:"
        kubectl exec -n "${NAMESPACE}" "${cilium_pod}" -- \
            cilium encrypt status 2>/dev/null | tee -a "${LOG_FILE}" || true
    fi
}

# =============================================================================
# 9. Nodes should now become Ready
# =============================================================================
wait_for_nodes_ready() {
    log_step "Waiting for All Nodes to Become Ready"

    local timeout=180
    local elapsed=0
    local interval=10

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local not_ready
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null \
            | awk '{if ($2 != "Ready") count++} END {print count+0}' || echo 1)

        if [[ ${not_ready} -eq 0 ]]; then
            log_ok "All nodes are Ready"
            kubectl get nodes -o wide | tee -a "${LOG_FILE}"
            return 0
        fi
        log_info "  ${not_ready} node(s) not yet Ready — waiting... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_warn "Some nodes still not Ready — check: kubectl get nodes -o wide"
    kubectl get nodes -o wide 2>/dev/null | tee -a "${LOG_FILE}" || true
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │    Cilium + WireGuard Installation            │"
    echo "  │       K3s — Offline Bundle                    │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    verify_prerequisites
    cleanup_stuck_namespaces
    load_images
    prepare_values
    check_existing_cilium
    deploy_cilium
    wait_for_cilium
    verify_wireguard
    wait_for_nodes_ready

    echo ""
    log_ok "Cilium ${CILIUM_VERSION} installed with WireGuard encryption. Log: ${LOG_FILE}"
    log_info ""
    log_info "Next step:"
    log_info "  sudo ./validate-cluster.sh --server-ip ${SERVER_IP}"
}

main "$@"
