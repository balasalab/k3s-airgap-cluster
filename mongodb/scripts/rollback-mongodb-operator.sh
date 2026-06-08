#!/bin/bash

################################################################################
# Percona MongoDB Operator — Offline Rollback
#
# Purpose: Restore a K3s cluster to its pre-upgrade state using a snapshot
#          captured by upgrade-mongodb-operator.sh.
#
# Usage:   sudo ./rollback-mongodb-operator.sh \
#            --rollback-dir /var/log/k3s-install/rollback/2026-06-02-10-30
#
# Rollback order (mandatory — do NOT reorder):
#   1. Restore operator (helm rollback or helm upgrade --install)
#   2. Restore CRDs     (kubectl apply --server-side)
#   3. Restore PSMDB CR (kubectl apply — old operator reconciles)
#
# Requirements:
#   - K3s cluster accessible
#   - kubectl and helm configured
#   - Root access (EUID=0)
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

ROLLBACK_DIR=""
MONGODB_NAMESPACE="mongodb"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
HELM_BIN="${HELM_BIN:-helm}"

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/mongodb-operator-rollback.log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Logging & Formatting
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
# Argument Parsing (task 3.2)
# =============================================================================

parse_args() {
    if [[ $# -eq 0 ]]; then
        log_error "No arguments provided."
        echo "  → Run with --rollback-dir /var/log/k3s-install/rollback/<timestamp>"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rollback-dir)  ROLLBACK_DIR="$2";       shift 2 ;;
            --namespace)     MONGODB_NAMESPACE="$2";  shift 2 ;;
            --kubeconfig)    KUBECONFIG="$2";         shift 2 ;;
            -h|--help)
                echo "Usage: sudo ./rollback-mongodb-operator.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --rollback-dir PATH  Path to rollback snapshot directory (required)"
                echo "  --namespace NAME     K8s namespace for operator (default: mongodb)"
                echo "  --kubeconfig PATH    Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)"
                echo "  -h, --help           Show this help"
                echo ""
                echo "Snapshot directories are at: /var/log/k3s-install/rollback/"
                echo "List available snapshots:"
                echo "  ls /var/log/k3s-install/rollback/"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "  → Run: sudo ./rollback-mongodb-operator.sh --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "${ROLLBACK_DIR}" ]]; then
        log_error "--rollback-dir is required."
        echo "  → Run with --rollback-dir /var/log/k3s-install/rollback/<timestamp>"
        echo "  → List snapshots: ls /var/log/k3s-install/rollback/"
        exit 1
    fi
}

# =============================================================================
# Initialization (task 3.3)
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}"

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}  ✘ ERROR: This script must be run as root (sudo)${NC}"
        exit 1
    fi

    export KUBECONFIG

    box "Percona MongoDB Operator — Rollback"

    log_info "Configuration:"
    log_info "  Rollback Dir : ${ROLLBACK_DIR}"
    log_info "  Namespace    : ${MONGODB_NAMESPACE}"
    log_info "  KUBECONFIG   : ${KUBECONFIG}"
}

# =============================================================================
# Snapshot Validation (task 3.4)
# =============================================================================

validate_snapshot() {
    log_step "Validating Rollback Snapshot"

    if [[ ! -d "${ROLLBACK_DIR}" ]]; then
        log_error "Rollback directory does not exist: ${ROLLBACK_DIR}"
        echo "  → List available snapshots: ls /var/log/k3s-install/rollback/"
        exit 1
    fi

    local required_files=(
        "helm-revision.txt"
        "helm-values.yaml"
        "crd-backup.yaml"
        "psmdb-cr-backup.yaml"
    )

    local missing=false

    for f in "${required_files[@]}"; do
        if [[ -f "${ROLLBACK_DIR}/${f}" ]]; then
            log_ok "${f}"
        else
            log_error "Missing required file: ${f}"
            echo "  → Manual recovery: see ROLLBACK-INSTRUCTIONS.txt in the snapshot directory"
            missing=true
        fi
    done

    if [[ "${missing}" == "true" ]]; then
        exit 1
    fi

    # old-chart.tgz is optional — only needed if Helm history has been purged.
    # In offline/airgap environments it may not have been captured (helm pull requires internet).
    if [[ -f "${ROLLBACK_DIR}/old-chart.tgz" ]]; then
        log_ok "old-chart.tgz (helm fallback available)"
    else
        log_warn "old-chart.tgz not found — rollback will use Helm history revision (offline-safe)"
    fi

    log_ok "Snapshot validation passed"
}

# =============================================================================
# Log Before Rollback State (task 3.5)
# =============================================================================

log_before_rollback() {
    log_step "Current State (CURRENT STATE — before rollback)"

    local op_version
    op_version=$(helm list --filter psmdb-operator -n "${MONGODB_NAMESPACE}" \
        --no-headers 2>/dev/null | awk '{print $9}' | sed 's/psmdb-operator-//' || echo "unknown")

    local mongo_image
    mongo_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.image}' 2>/dev/null || echo "unknown")

    local backup_image
    backup_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.backup.image}' 2>/dev/null || echo "unknown")

    printf "  %-20s %s\n" "Operator version :" "${op_version}"
    printf "  %-20s %s\n" "MongoDB image    :" "${mongo_image}"
    printf "  %-20s %s\n" "Backup image     :" "${backup_image}"
    echo "" | tee -a "${LOG_FILE}"
}

# =============================================================================
# STEP 1: Restore Operator (task 3.6)
# Must run FIRST — old operator must be running before CRDs and CR are touched
# =============================================================================

restore_operator() {
    log_step "Step 1/3: Restoring Operator"

    local saved_revision
    saved_revision=$(cat "${ROLLBACK_DIR}/helm-revision.txt" 2>/dev/null | tr -d '[:space:]')

    log_info "  Saved revision: ${saved_revision:-<empty>}"

    # Check if the saved revision exists in Helm history
    local use_rollback=false
    if [[ -n "${saved_revision}" ]] \
       && helm history psmdb-operator -n "${MONGODB_NAMESPACE}" 2>/dev/null \
          | grep -q "^${saved_revision}[[:space:]]"; then
        use_rollback=true
    fi

    if [[ "${use_rollback}" == "true" ]]; then
        log_info "  Using: helm rollback (revision ${saved_revision})"
        if helm rollback psmdb-operator "${saved_revision}" \
            -n "${MONGODB_NAMESPACE}" --wait \
            2>&1 | tee -a "${LOG_FILE}"; then
            log_ok "Operator rolled back to revision ${saved_revision}"
        else
            log_error "helm rollback failed"
            echo "  → Try: sudo ./rollback-mongodb-operator.sh --rollback-dir ${ROLLBACK_DIR}"
            exit 1
        fi
    else
        log_warn "Helm revision '${saved_revision}' not found in history — falling back to helm upgrade --install"

        if [[ ! -f "${ROLLBACK_DIR}/old-chart.tgz" ]]; then
            log_error "old-chart.tgz is missing and Helm history revision '${saved_revision}' is not available."
            echo "  → In offline environments, re-install the operator from the original upgrade bundle:"
            echo "      helm upgrade --install psmdb-operator <chart.tgz from bundle> \\"
            echo "        --values ${ROLLBACK_DIR}/helm-values.yaml \\"
            echo "        --namespace ${MONGODB_NAMESPACE} --wait"
            exit 1
        fi

        log_info "  Using: helm upgrade --install with old-chart.tgz + helm-values.yaml"

        if helm upgrade --install psmdb-operator "${ROLLBACK_DIR}/old-chart.tgz" \
            --values "${ROLLBACK_DIR}/helm-values.yaml" \
            --namespace "${MONGODB_NAMESPACE}" \
            --wait \
            2>&1 | tee -a "${LOG_FILE}"; then
            log_ok "Operator restored via helm upgrade --install (fallback path)"
        else
            log_error "helm upgrade --install fallback failed"
            exit 1
        fi
    fi

    # Wait for operator to be ready before proceeding to CRD restore
    log_info "  Waiting for operator readiness before applying CRDs..."
    local timeout=300 elapsed=0 interval=5

    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(kubectl get deployment -n "${MONGODB_NAMESPACE}" \
            -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
        if [[ "${ready}" -ge 1 ]]; then
            log_ok "Operator is ready (${elapsed}s)"
            break
        fi
        log_info "  Waiting... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_warn "Operator not ready after ${timeout}s — proceeding with CRD restore anyway"
    fi
}

# =============================================================================
# STEP 2: Restore CRDs (task 3.7)
# Must run AFTER operator, BEFORE PSMDB CR
# =============================================================================

restore_crds() {
    log_step "Step 2/3: Restoring CRDs"

    # Strip resourceVersion before applying — stale versions in the snapshot cause
    # optimistic concurrency failures even with --force-conflicts.
    grep -v "^\s*resourceVersion:" "${ROLLBACK_DIR}/crd-backup.yaml" | \
        kubectl apply --server-side --force-conflicts -f - \
        2>&1 | tee -a "${LOG_FILE}"

    local crd_count
    # kubectl get -o yaml produces a List, so "kind:" is indented — use flexible whitespace match
    crd_count=$(grep -c "[[:space:]]kind: CustomResourceDefinition" "${ROLLBACK_DIR}/crd-backup.yaml" 2>/dev/null || true)
    crd_count="${crd_count:-0}"
    log_ok "CRDs restored (${crd_count} resource definition(s))"
}

# =============================================================================
# STEP 3: Restore PSMDB CR (task 3.8)
# Must run LAST — after old operator is running with correct CRD schema
# =============================================================================

restore_mongodb_cr() {
    log_step "Step 3/3: Restoring PSMDB Custom Resources"

    # Log what images are being restored
    log_info "  Restoring MongoDB images from snapshot..."
    local mongo_image
    mongo_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.image}' 2>/dev/null || echo "unknown")
    local backup_image
    backup_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.backup.image}' 2>/dev/null || echo "unknown")
    log_info "  Current  → spec.image       : ${mongo_image}"
    log_info "  Current  → spec.backup.image: ${backup_image}"

    # Strip resourceVersion before applying — stale versions in the snapshot cause
    # optimistic concurrency failures even with --force-conflicts.
    grep -v "^\s*resourceVersion:" "${ROLLBACK_DIR}/psmdb-cr-backup.yaml" | \
        kubectl apply --server-side --force-conflicts -f - \
        2>&1 | tee -a "${LOG_FILE}"

    local restored_mongo
    restored_mongo=$(grep -m1 'image:' "${ROLLBACK_DIR}/psmdb-cr-backup.yaml" 2>/dev/null | awk '{print $2}' || echo "see snapshot")
    log_ok "PSMDB CR restored — operator will trigger rolling restart to pre-upgrade images"
    log_info "  Old operator is now reconciling the restored CR"
}

# =============================================================================
# Verify Rollback (task 3.9)
# =============================================================================

verify_rollback() {
    log_step "Verifying Rollback"

    log_info "  Waiting for operator to be ready..."

    local timeout=600 elapsed=0 interval=10

    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(kubectl get deployment -n "${MONGODB_NAMESPACE}" \
            -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)

        if [[ "${ready}" -ge 1 ]]; then
            log_ok "Operator is ready (${elapsed}s)"
            break
        fi

        log_info "  Waiting for operator... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_warn "Operator not ready after ${timeout}s"
        log_warn "Diagnostic commands:"
        log_warn "  kubectl get psmdb -n ${MONGODB_NAMESPACE}"
        log_warn "  kubectl get pods -n ${MONGODB_NAMESPACE}"
        log_warn "  kubectl logs deploy/psmdb-operator -n ${MONGODB_NAMESPACE} --tail=50"
        return 0
    fi

    # Wait for PSMDB cluster to reach ready state
    log_info "  Waiting for PSMDB cluster to reach 'ready' state..."
    elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local psmdb_state
        psmdb_state=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
            -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "unknown")

        if [[ "${psmdb_state}" == "ready" ]]; then
            log_ok "PSMDB cluster is ready (${elapsed}s)"
            return 0
        fi

        log_info "  PSMDB state: ${psmdb_state} (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_warn "PSMDB cluster did not reach 'ready' state within ${timeout}s"
    log_warn "Diagnostic commands:"
    log_warn "  kubectl get psmdb -n ${MONGODB_NAMESPACE}"
    log_warn "  kubectl get pods -n ${MONGODB_NAMESPACE}"
    log_warn "  kubectl logs deploy/psmdb-operator -n ${MONGODB_NAMESPACE} --tail=50"
    return 0
}

# =============================================================================
# Output Info (task 3.10)
# =============================================================================

output_info() {
    log_step "Rollback Complete — AFTER ROLLBACK State"

    local op_version
    op_version=$(helm list --filter psmdb-operator -n "${MONGODB_NAMESPACE}" \
        --no-headers 2>/dev/null | awk '{print $9}' | sed 's/psmdb-operator-//' || echo "unknown")

    local mongo_image
    mongo_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.image}' 2>/dev/null || echo "unknown")

    local backup_image
    backup_image=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[0].spec.backup.image}' 2>/dev/null || echo "unknown")

    printf "  %-20s %s\n" "Operator version :" "${op_version}"
    printf "  %-20s %s\n" "MongoDB image    :" "${mongo_image}"
    printf "  %-20s %s\n" "Backup image     :" "${backup_image}"

    echo ""
    box "Rollback Complete — Pre-Upgrade State Restored!"
    echo ""

    echo "  Verify cluster state:"
    echo "    kubectl get psmdb -n ${MONGODB_NAMESPACE}"
    echo "    kubectl get pods -n ${MONGODB_NAMESPACE}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    init
    validate_snapshot
    log_before_rollback

    # Rollback in mandatory order: operator → CRDs → PSMDB CR
    restore_operator
    restore_crds
    restore_mongodb_cr

    verify_rollback
    output_info

    log_info "Rollback finished."
    log_info "Logs: ${LOG_FILE}"
}

main "$@"
