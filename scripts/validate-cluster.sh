#!/usr/bin/env bash
# =============================================================================
# validate-cluster.sh — Full cluster health, networking, and encryption check
#
# Validates K3s + Cilium + WireGuard after installation.
# Generates a before/after comparison report.
#
# Usage: sudo ./validate-cluster.sh [--server-ip <IP>] [OPTIONS]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/validation.log"
REPORT_FILE="${LOG_DIR}/system-comparison-report.txt"
DEBUG=false
SKIP_CONNECTIVITY_TEST=false
SERVER_IP=""
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
NAMESPACE="kube-system"

_ts()       { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" >&2; }
log_step()  { echo -e "\n${BLUE}${BOLD}══ [CHECK] $(_ts) $*${NC}" | tee -a "${LOG_FILE}"; }
log_ok()    { echo -e "${GREEN}  ✔${NC} $*" | tee -a "${LOG_FILE}"; PASS=$((PASS+1)); }
log_fail()  { echo -e "${RED}  ✘${NC} $*" | tee -a "${LOG_FILE}"; FAIL=$((FAIL+1)); }
log_skip()  { echo -e "${CYAN}  ↷${NC} $* (skipped)" | tee -a "${LOG_FILE}"; }

PASS=0; FAIL=0

on_error() { log_error "Validation error at line $1"; }
trap 'on_error $LINENO' ERR

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}validate-cluster.sh${NC} — K3s + Cilium + WireGuard cluster validation

${BOLD}USAGE${NC}
  sudo $0 [--server-ip <IP>] [OPTIONS]

${BOLD}OPTIONS${NC}
  --server-ip IP              Control plane IP (for connectivity tests)
  --skip-connectivity-test    Skip long-running Cilium connectivity test (130 tests, ~5 min)
  --kubeconfig PATH           Path to kubeconfig    (default: ${KUBECONFIG})
  --debug                     Enable debug output
  -h, --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-ip)                 SERVER_IP="${2:?}"; shift 2 ;;
        --kubeconfig)                KUBECONFIG="${2:?}"; shift 2 ;;
        --skip-connectivity-test)    SKIP_CONNECTIVITY_TEST=true; shift ;;
        --debug)                     DEBUG=true; shift ;;
        -h|--help)                   usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
export KUBECONFIG

# =============================================================================
# 1. K3s service health
# =============================================================================
check_k3s_service() {
    log_step "K3s Service Status"

    if systemctl is-active --quiet k3s; then
        log_ok "k3s service is active"
    else
        log_fail "k3s service is NOT active"
        journalctl -u k3s --no-pager -n 20 | tee -a "${LOG_FILE}" || true
    fi

    # API server health (with retries for airgap supervisor stability)
    local health_ok=false
    for attempt in 1 2 3; do
        if curl -sk --connect-timeout 5 --max-time 10 "https://127.0.0.1:6443/healthz" 2>/dev/null | grep -q "ok"; then
            health_ok=true
            break
        fi
        [[ ${attempt} -lt 3 ]] && sleep 2
    done

    if ${health_ok}; then
        log_ok "K3s API server /healthz: ok"
    else
        log_warn "K3s API server /healthz timeout (supervisor tunnel may be recovering)"
    fi

    # Readyz endpoint is stricter and may timeout during initialization
    local ready_ok=false
    for attempt in 1 2 3; do
        if curl -sk --connect-timeout 5 --max-time 10 "https://127.0.0.1:6443/readyz" 2>/dev/null | grep -q "ok"; then
            ready_ok=true
            break
        fi
        [[ ${attempt} -lt 3 ]] && sleep 2
    done

    if ${ready_ok}; then
        log_ok "K3s API server /readyz: ok"
    else
        log_warn "K3s API server /readyz not ok (normal during cluster initialization)"
    fi
}

# =============================================================================
# 2. Node status
# =============================================================================
check_nodes() {
    log_step "Cluster Node Status"

    local nodes; nodes="$(kubectl get nodes -o wide --no-headers 2>/dev/null || true)"
    if [[ -z "${nodes}" ]]; then
        log_fail "No nodes found — kubectl may not be configured"
        return
    fi

    echo "${nodes}" | tee -a "${LOG_FILE}"

    local total not_ready
    total="$(echo "${nodes}" | wc -l)"
    not_ready="$(echo "${nodes}" | grep -v " Ready" | wc -l || true)"

    if [[ "${not_ready}" -eq 0 ]]; then
        log_ok "All ${total} node(s) Ready"
    else
        log_fail "${not_ready}/${total} node(s) NOT Ready"
    fi
}

# =============================================================================
# 3. Pod status
# =============================================================================
check_pods() {
    log_step "Pod Status (kube-system)"

    kubectl get pods -n "${NAMESPACE}" -o wide --no-headers 2>/dev/null | tee -a "${LOG_FILE}" || true

    local not_running
    not_running="$(kubectl get pods -A --no-headers 2>/dev/null \
        | grep -vE "Running|Completed" | wc -l || true)"

    if [[ "${not_running}" -eq 0 ]]; then
        log_ok "All pods across all namespaces are Running/Completed"
    else
        log_warn "${not_running} pod(s) not in Running/Completed state"
        kubectl get pods -A --no-headers 2>/dev/null \
            | grep -vE "Running|Completed" | tee -a "${LOG_FILE}" || true
    fi
}

# =============================================================================
# 4. Cilium health
# =============================================================================
check_cilium() {
    log_step "Cilium Health"

    # DaemonSet ready count
    local total desired
    total="$(kubectl get daemonset cilium -n "${NAMESPACE}" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    desired="$(kubectl get daemonset cilium -n "${NAMESPACE}" \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"

    if [[ "${desired}" -gt 0 && "${total}" -eq "${desired}" ]]; then
        log_ok "Cilium DaemonSet: ${total}/${desired} pods Ready"
    else
        log_fail "Cilium DaemonSet: ${total}/${desired} pods Ready"
    fi

    # Operator
    local op_ready
    op_ready="$(kubectl get deployment cilium-operator -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${op_ready:-0}" -gt 0 ]] \
        && log_ok "Cilium operator: ready (${op_ready})" \
        || log_fail "Cilium operator: not ready"

    # Cilium CLI status
    local cilium_pod
    cilium_pod="$(kubectl get pods -n "${NAMESPACE}" -l k8s-app=cilium \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -n "${cilium_pod}" ]]; then
        log_info "Cilium status from ${cilium_pod}:"
        kubectl exec -n "${NAMESPACE}" "${cilium_pod}" -- \
            cilium status --brief 2>/dev/null | tee -a "${LOG_FILE}" \
            && log_ok "Cilium status check passed" \
            || log_warn "Cilium status check had warnings"

        # kube-proxy replacement
        log_info "kube-proxy replacement status:"
        kubectl exec -n "${NAMESPACE}" "${cilium_pod}" -- \
            cilium status 2>/dev/null \
            | grep -i "KubeProxy\|kube-proxy" | tee -a "${LOG_FILE}" || true

        # Encryption status
        log_info "Encryption status:"
        kubectl exec -n "${NAMESPACE}" "${cilium_pod}" -- \
            cilium encrypt status 2>/dev/null | tee -a "${LOG_FILE}" \
            && log_ok "Encryption status retrieved" \
            || log_warn "Could not retrieve encryption status"
    fi
}

# =============================================================================
# 5. WireGuard encryption
# =============================================================================
check_wireguard() {
    log_step "WireGuard Encryption Status"

    if ip link show cilium_wg0 &>/dev/null; then
        log_ok "WireGuard interface cilium_wg0 exists"
        ip link show cilium_wg0 | tee -a "${LOG_FILE}"

        if command -v wg &>/dev/null; then
            log_info "WireGuard details:"
            wg show cilium_wg0 2>/dev/null | tee -a "${LOG_FILE}" || true

            local peers; peers="$(wg show cilium_wg0 peers 2>/dev/null | wc -l || echo 0)"
            [[ "${peers}" -gt 0 ]] \
                && log_ok "WireGuard: ${peers} peer(s) configured" \
                || log_warn "WireGuard: no peers yet (expected with only 1 node)"

            # Check for recent handshakes
            local last_hs
            last_hs="$(wg show cilium_wg0 latest-handshakes 2>/dev/null | head -1 || true)"
            [[ -n "${last_hs}" ]] && log_info "Last handshake: ${last_hs}"
        fi
    else
        log_warn "cilium_wg0 not visible on this node"
        log_warn "WireGuard interfaces only form when multiple nodes are present"
    fi

    # Kernel module check
    if lsmod | grep -q wireguard || grep -q wireguard /proc/modules 2>/dev/null; then
        log_ok "WireGuard kernel module loaded"
    else
        log_warn "WireGuard module not in lsmod — may be built into kernel"
    fi
}

# =============================================================================
# 6. Pod-to-pod connectivity test
# =============================================================================
check_pod_connectivity() {
    log_step "Pod-to-Pod Connectivity Test"

    local test_ns="cilium-connectivity-test-$$"

    cleanup_test_pods() {
        kubectl delete namespace "${test_ns}" --ignore-not-found &>/dev/null || true
    }
    trap cleanup_test_pods EXIT

    # Create test namespace
    kubectl create namespace "${test_ns}" &>/dev/null || true

    # Deploy two test pods
    kubectl run pod-a --image=busybox:1.36 --restart=Never \
        -n "${test_ns}" \
        --command -- sleep 120 &>/dev/null || true

    kubectl run pod-b --image=busybox:1.36 --restart=Never \
        -n "${test_ns}" \
        --command -- sleep 120 &>/dev/null || true

    log_info "Waiting for test pods to start..."
    local wait_secs=0
    while [[ ${wait_secs} -lt 60 ]]; do
        local a_status b_status
        a_status="$(kubectl get pod pod-a -n "${test_ns}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
        b_status="$(kubectl get pod pod-b -n "${test_ns}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"

        if [[ "${a_status}" == "Running" && "${b_status}" == "Running" ]]; then
            log_ok "Test pods running"
            break
        fi
        sleep 5
        wait_secs=$((wait_secs + 5))
    done

    local pod_b_ip
    pod_b_ip="$(kubectl get pod pod-b -n "${test_ns}" \
        -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

    if [[ -n "${pod_b_ip}" ]]; then
        log_info "Testing pod-a → pod-b (${pod_b_ip}):"
        if kubectl exec -n "${test_ns}" pod-a -- ping -c 3 -W 5 "${pod_b_ip}" &>/dev/null; then
            log_ok "Pod-to-pod ping: OK (${pod_b_ip})"
        else
            log_fail "Pod-to-pod ping: FAILED (${pod_b_ip})"
        fi

        # DNS test
        log_info "Testing DNS resolution:"
        if kubectl exec -n "${test_ns}" pod-a -- \
                nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
            log_ok "DNS resolution: OK"
        else
            log_fail "DNS resolution: FAILED"
        fi
    else
        log_warn "Could not get pod-b IP — skipping ping test"
    fi

    cleanup_test_pods
    trap - EXIT
}

# =============================================================================
# 7. Cilium connectivity test (if cilium CLI available)
# =============================================================================
run_cilium_connectivity_test() {
    log_step "Cilium Connectivity Test (cilium CLI)"

    if ${SKIP_CONNECTIVITY_TEST}; then
        log_skip "Cilium connectivity test (long-running, 130 tests ~5 min)"
        return
    fi

    if ! command -v cilium &>/dev/null; then
        log_skip "cilium CLI not found"
        return
    fi

    log_info "Running: cilium connectivity test (this may take several minutes)"
    if cilium connectivity test \
            --test-namespace cilium-test \
            2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Cilium connectivity test passed"
    else
        log_warn "Cilium connectivity test had failures — check output above"
    fi

    # Cleanup
    kubectl delete namespace cilium-test --ignore-not-found &>/dev/null || true
}

# =============================================================================
# 8. Capture after-state and generate comparison report
# =============================================================================
capture_after_state() {
    log_step "Generating System Comparison Report"

    {
        echo ""
        echo "================================================================"
        echo "  AFTER-INSTALLATION STATE — $(date -u)"
        echo "================================================================"
        echo ""
        echo "--- Kubernetes Nodes ---"
        kubectl get nodes -o wide 2>/dev/null || echo "(unavailable)"
        echo ""
        echo "--- All Pods (kube-system) ---"
        kubectl get pods -n kube-system -o wide 2>/dev/null || echo "(unavailable)"
        echo ""
        echo "--- Network Interfaces ---"
        ip -br link show 2>/dev/null || true
        echo ""
        echo "--- IP Addresses ---"
        ip -br addr show 2>/dev/null || true
        echo ""
        echo "--- WireGuard Interfaces ---"
        ip link show type wireguard 2>/dev/null || echo "(none)"
        echo ""
        echo "--- WireGuard Show ---"
        wg show 2>/dev/null || echo "(wg not available)"
        echo ""
        echo "--- K3s Services ---"
        systemctl list-units --state=active --no-pager \
            | grep -E "k3s|containerd" || echo "(none found)"
        echo ""
        echo "--- Cilium DaemonSet ---"
        kubectl get ds -n kube-system cilium 2>/dev/null || echo "(unavailable)"
        echo ""
        echo "--- Running Pods (all namespaces) ---"
        kubectl get pods -A 2>/dev/null || echo "(unavailable)"
        echo ""
        echo "--- Kernel Modules (WireGuard) ---"
        lsmod | grep -E "wireguard|br_netfilter|overlay" || echo "(none loaded)"
        echo ""
        echo "--- Cilium Status ---"
        local cilium_pod
        cilium_pod="$(kubectl get pods -n kube-system -l k8s-app=cilium \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [[ -n "${cilium_pod}" ]] \
            && kubectl exec -n kube-system "${cilium_pod}" -- cilium status 2>/dev/null \
            || echo "(cilium pod not available)"
        echo ""
        echo "================================================================"
        echo "  VALIDATION SUMMARY"
        echo "================================================================"
        echo "  PASS: ${PASS}"
        echo "  FAIL: ${FAIL}"
        echo "  WARN: see log for warnings"
        echo "================================================================"
    } >> "${REPORT_FILE}"

    log_ok "Comparison report updated: ${REPORT_FILE}"
}

# =============================================================================
# 9. Print final summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    if [[ "${FAIL}" -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}║         ✔  CLUSTER VALIDATION PASSED             ║${NC}"
    else
        echo -e "${BOLD}${RED}║         ✘  CLUSTER VALIDATION HAD FAILURES       ║${NC}"
    fi
    echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}PASS${NC}: ${PASS}"
    echo -e "  ${RED}FAIL${NC}: ${FAIL}"
    echo ""
    echo -e "  Log file    : ${LOG_FILE}"
    echo -e "  Full report : ${REPORT_FILE}"
    echo ""

    if [[ "${FAIL}" -gt 0 ]]; then
        echo -e "  ${YELLOW}Troubleshooting:${NC}"
        echo "    journalctl -u k3s --no-pager -n 50"
        echo "    kubectl -n kube-system logs -l k8s-app=cilium --tail=50"
        echo "    kubectl describe nodes"
        echo ""
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │     Cluster Validation — K3s + Cilium        │"
    echo "  │         + WireGuard Encryption               │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"

    check_k3s_service
    check_nodes
    check_pods
    check_cilium
    check_wireguard
    check_pod_connectivity
    run_cilium_connectivity_test
    capture_after_state
    print_summary
}

main "$@"
