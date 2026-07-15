#!/bin/bash

################################################################################
# Kafka Cleanup / Rollback Script
#
# Purpose: Completely remove all Strimzi + Kafka resources from the K3s cluster.
#          Safe to run after a partial or failed install.
#          Handles stuck finalizers, CRDs, and ClusterRoles helm uninstall misses.
#
# Usage:   sudo ./cleanup-kafka.sh [OPTIONS]
#
# WARNING: This deletes all Kafka data (PVCs) and is NOT reversible.
#          Only run this if you intend to fully remove Kafka from the cluster.
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
HELM_RELEASE="strimzi-operator"
HELM_BIN="${HELM_BIN:-helm}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

LOG_DIR="/var/log/k3s-install"
STEP_DIR="${LOG_DIR}/.steps-kafka"
LOG_FILE="${LOG_DIR}/kafka-cleanup.log"

FORCE="${FORCE:-false}"

# =============================================================================
# Color Codes
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Logging
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC}  $(date +'%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

log_ok() {
    echo -e "${GREEN}  ✔ $*${NC}" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo -e "${YELLOW}  ⚠ $*${NC}" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}  ✘ ERROR: $*${NC}" | tee -a "${LOG_FILE}"
}

log_step() {
    echo -e "${BLUE}══ [STEP] $(date +'%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "${LOG_FILE}"
}

box() {
    local text="$1"
    local width=$((${#text} + 4))
    printf "  ┌%s┐\n" "$(printf '─%.0s' $(seq 1 $((width - 2))))"
    printf "  │ %s │\n" "$text"
    printf "  └%s┘\n" "$(printf '─%.0s' $(seq 1 $((width - 2))))"
}

# =============================================================================
# Initialization
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    export KUBECONFIG

    box "Kafka Cleanup / Rollback"

    log_warn "This will permanently remove all Kafka resources from namespace '${KAFKA_NAMESPACE}'."
    log_warn "All broker PVCs (data) will also be deleted."
    echo ""

    if [[ "${FORCE}" != "true" ]]; then
        read -r -p "  Confirm: type 'yes' to proceed: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            echo "  Aborted."
            exit 0
        fi
    fi

    log_info "Log file: ${LOG_FILE}"
    echo ""
}

# =============================================================================
# Step 1 — Remove Finalizers from Strimzi CRs (prevents stuck deletes)
# =============================================================================
# When the operator is down, Kafka CRs with finalizers get stuck in Terminating.
# We patch them out first so deletion completes immediately.

remove_finalizers() {
    log_step "Step 1 — Removing Finalizers from Strimzi CRs"

    local crds=("kafkas" "kafkanodepools" "kafkatopics" "kafkausers"
                 "kafkaconnects" "kafkaconnectors" "kafkabridges"
                 "kafkamirrormakers" "kafkamirrormaker2s" "kafkarebalances")

    for crd in "${crds[@]}"; do
        # Only try if the CRD exists
        if kubectl get crd "${crd}.kafka.strimzi.io" &>/dev/null 2>&1; then
            local resources
            resources=$(kubectl get "${crd}" -n "${KAFKA_NAMESPACE}" \
                -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            for res in ${resources}; do
                log_info "Removing finalizers from ${crd}/${res}"
                kubectl patch "${crd}" "${res}" -n "${KAFKA_NAMESPACE}" \
                    -p '{"metadata":{"finalizers":[]}}' \
                    --type=merge 2>&1 | tee -a "${LOG_FILE}" || true
            done
        fi
    done

    log_ok "Finalizer removal complete"
}

# =============================================================================
# Step 2 — Delete Strimzi CRs
# =============================================================================

delete_kafka_resources() {
    log_step "Step 2 — Deleting Strimzi Custom Resources"

    local crds=("kafkas" "kafkanodepools" "kafkatopics" "kafkausers"
                 "kafkaconnects" "kafkaconnectors" "kafkabridges"
                 "kafkamirrormakers" "kafkamirrormaker2s" "kafkarebalances")

    for crd in "${crds[@]}"; do
        if kubectl get crd "${crd}.kafka.strimzi.io" &>/dev/null 2>&1; then
            local count
            count=$(kubectl get "${crd}" -n "${KAFKA_NAMESPACE}" \
                --no-headers 2>/dev/null | wc -l || echo 0)
            if [[ "${count}" -gt 0 ]]; then
                log_info "Deleting all ${crd} in ${KAFKA_NAMESPACE}"
                kubectl delete "${crd}" --all -n "${KAFKA_NAMESPACE}" \
                    --timeout=30s 2>&1 | tee -a "${LOG_FILE}" || true
            fi
        fi
    done

    log_ok "Strimzi CRs deleted"
}

# =============================================================================
# Step 3 — Uninstall Strimzi Helm Release
# =============================================================================

uninstall_helm_release() {
    log_step "Step 3 — Uninstalling Helm Release"

    if $HELM_BIN list -n "${KAFKA_NAMESPACE}" 2>/dev/null | grep -q "${HELM_RELEASE}"; then
        $HELM_BIN uninstall "${HELM_RELEASE}" -n "${KAFKA_NAMESPACE}" \
            --timeout=2m \
            2>&1 | tee -a "${LOG_FILE}"
        log_ok "Helm release '${HELM_RELEASE}' uninstalled"
    else
        log_warn "Helm release '${HELM_RELEASE}' not found — skipping"
    fi
}

# =============================================================================
# Step 4 — Delete PVCs
# =============================================================================

delete_pvcs() {
    log_step "Step 4 — Deleting PVCs (broker storage)"

    local pvc_count
    pvc_count=$(kubectl get pvc -n "${KAFKA_NAMESPACE}" \
        --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ "${pvc_count}" -gt 0 ]]; then
        log_info "Found ${pvc_count} PVC(s) — deleting"
        kubectl delete pvc --all -n "${KAFKA_NAMESPACE}" \
            2>&1 | tee -a "${LOG_FILE}" || true
        log_ok "PVCs deleted"
    else
        log_info "No PVCs found in ${KAFKA_NAMESPACE}"
    fi
}

# =============================================================================
# Step 5 — Delete Namespace
# =============================================================================

delete_namespace() {
    log_step "Step 5 — Deleting Namespace '${KAFKA_NAMESPACE}'"

    if kubectl get namespace "${KAFKA_NAMESPACE}" &>/dev/null 2>&1; then
        kubectl delete namespace "${KAFKA_NAMESPACE}" \
            --timeout=60s \
            2>&1 | tee -a "${LOG_FILE}" || {
            log_warn "Namespace delete timed out — force-removing finalizers"
            kubectl patch namespace "${KAFKA_NAMESPACE}" \
                -p '{"metadata":{"finalizers":[]}}' \
                --type=merge 2>&1 | tee -a "${LOG_FILE}" || true
        }
        log_ok "Namespace '${KAFKA_NAMESPACE}' deleted"
    else
        log_warn "Namespace '${KAFKA_NAMESPACE}' not found — skipping"
    fi
}

# =============================================================================
# Step 6 — Delete Strimzi CRDs (cluster-scoped; helm uninstall leaves these)
# =============================================================================

delete_crds() {
    log_step "Step 6 — Deleting Strimzi CRDs"

    local crd_count
    crd_count=$(kubectl get crd -l app=strimzi \
        --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ "${crd_count}" -gt 0 ]]; then
        log_info "Found ${crd_count} Strimzi CRD(s) — deleting"
        kubectl delete crd -l app=strimzi \
            2>&1 | tee -a "${LOG_FILE}"
        log_ok "Strimzi CRDs deleted"
    else
        log_info "No Strimzi CRDs found (already removed or never installed)"
    fi
}

# =============================================================================
# Step 7 — Clean Cluster-Scoped RBAC (ClusterRoles helm uninstall may miss)
# =============================================================================

delete_cluster_rbac() {
    log_step "Step 7 — Cleaning Cluster-Scoped RBAC"

    # Delete any strimzi ClusterRoles/Bindings not removed by helm uninstall
    local roles
    roles=$(kubectl get clusterrole,clusterrolebinding \
        -l app=strimzi --no-headers 2>/dev/null \
        | awk '{print $1}' || echo "")

    if [[ -n "${roles}" ]]; then
        kubectl delete clusterrole,clusterrolebinding \
            -l app=strimzi 2>&1 | tee -a "${LOG_FILE}" || true
        log_ok "Cluster-scoped RBAC removed"
    else
        log_info "No strimzi ClusterRoles/Bindings found"
    fi
}

# =============================================================================
# Step 8 — Clean Step Tracking Files
# =============================================================================

clean_step_tracking() {
    log_step "Step 8 — Cleaning Step Tracking Files"

    if [[ -d "${STEP_DIR}" ]]; then
        rm -rf "${STEP_DIR}"
        log_ok "Removed: ${STEP_DIR}"
    else
        log_info "Step tracking directory not found — skipping"
    fi
}

# =============================================================================
# Summary
# =============================================================================

summary() {
    echo ""
    box "Kafka Cleanup Complete"
    echo ""
    log_ok "Namespace '${KAFKA_NAMESPACE}' removed"
    log_ok "Strimzi operator Helm release removed"
    log_ok "Strimzi CRDs removed"
    log_ok "Step tracking cleared"
    echo ""
    echo "  To reinstall Kafka:"
    echo "    sudo ./kafka_setup/scripts/install-kafka.sh --bundle-path /opt/kafka-bundle-prep"
    echo ""
    echo "  Cleanup log: ${LOG_FILE}"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)
                KAFKA_NAMESPACE="$2"
                shift 2
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --kubeconfig)
                KUBECONFIG="$2"
                shift 2
                ;;
            -h|--help)
                cat << 'HELP'
Usage: sudo ./cleanup-kafka.sh [OPTIONS]

Removes all Strimzi Kafka resources from the K3s cluster.
Safe to run after a partial or failed install.

Options:
  --namespace NAME    Kafka namespace to remove (default: kafka)
  --force             Skip confirmation prompt
  --kubeconfig PATH   Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)
  -h, --help          Show this help message

Examples:
  sudo ./cleanup-kafka.sh                       # interactive confirmation
  sudo ./cleanup-kafka.sh --force               # non-interactive (CI/automation)
  sudo ./cleanup-kafka.sh --namespace kafka     # explicit namespace

What this removes:
  - Strimzi CRs (Kafka, KafkaNodePool, KafkaTopic, etc.)
  - Strimzi operator Helm release
  - All PVCs in the kafka namespace (broker data)
  - kafka namespace
  - Strimzi CRDs (cluster-scoped — helm uninstall skips these)
  - Strimzi ClusterRoles and ClusterRoleBindings
  - Step tracking files (/var/log/k3s-install/.steps-kafka/)
HELP
                exit 0
                ;;
            *)
                echo -e "${RED}  ✘ ERROR: Unknown option: $1. Use --help for usage.${NC}"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    init
    remove_finalizers
    delete_kafka_resources
    uninstall_helm_release
    delete_pvcs
    delete_namespace
    delete_crds
    delete_cluster_rbac
    clean_step_tracking
    summary

    log_info "Kafka cleanup finished"
    log_info "Log available at: ${LOG_FILE}"
}

main "$@"
