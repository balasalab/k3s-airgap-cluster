#!/bin/bash

################################################################################
# Strimzi Kafka Operator — Offline Rollback (Operator Only, Data-Safe)
#
# Purpose: Roll back the Strimzi operator to a previous version using the
#          snapshot created by upgrade-kafka.sh. Broker topic data is
#          NEVER modified.
#
# Usage:   sudo ./rollback-kafka.sh \
#            --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z
#
# DATA SAFETY CONTRACT:
#   This script performs operator rollback ONLY. The Kafka broker version
#   (spec.kafka.version) is NOT downgraded because Kafka does not support
#   broker version downgrade once data has been written in the new format.
#   The metadataVersion is restored to allow the older operator to manage
#   the cluster correctly.
#
# Requirements:
#   - Snapshot directory produced by upgrade-kafka.sh
#   - kubectl and helm available
#   - Root access on the cluster node
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

SNAPSHOT_DIR="${SNAPSHOT_DIR:-}"
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_CLUSTER_NAME="${KAFKA_CLUSTER_NAME:-kafka-cluster}"
KAFKA_POOL_NAME="${KAFKA_POOL_NAME:-kafka}"
HELM_RELEASE="${HELM_RELEASE:-strimzi-operator}"
HELM_BIN="${HELM_BIN:-helm}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
FORCE="${FORCE:-false}"

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/kafka-rollback.log"

OPERATOR_READY_TIMEOUT=120  # seconds
KAFKA_STABLE_TIMEOUT=300    # seconds

# Populated by validate_snapshot()
SNAPSHOT_FROM_STRIMZI=""
SNAPSHOT_TO_STRIMZI=""
SNAPSHOT_FROM_KAFKA=""
SNAPSHOT_HELM_REVISION=""
SNAPSHOT_META_VERSION=""
CURRENT_KAFKA_VERSION=""

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

    box "Strimzi Kafka — Operator Rollback (Data-Safe)"

    log_info "Snapshot dir:  ${SNAPSHOT_DIR}"
    log_info "Namespace:     ${KAFKA_NAMESPACE}"
    log_info "Helm release:  ${HELM_RELEASE}"
    log_info "Force:         ${FORCE}"
    log_info "KUBECONFIG:    ${KUBECONFIG}"
    log_info "Log file:      ${LOG_FILE}"
}

# =============================================================================
# Step 1 — Validate snapshot directory
# =============================================================================

validate_snapshot() {
    log_step "Step 1 — Validating Snapshot"

    if [[ -z "${SNAPSHOT_DIR}" ]]; then
        log_error "--snapshot-dir is required."
        log_error ""
        log_error "The snapshot directory is created by upgrade-kafka.sh before each upgrade."
        log_error "It is printed at the end of a successful upgrade run."
        log_error ""
        log_error "Example:"
        log_error "  sudo ./rollback-kafka.sh --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z"
        log_error ""
        log_error "Available snapshots (newest first):"
        ls -1t /var/log/k3s-install/kafka-snapshots/ 2>/dev/null \
            | while read -r d; do echo "    /var/log/k3s-install/kafka-snapshots/${d}"; done \
            | head -10 || echo "    (no snapshots found)"
        exit 1
    fi

    if [[ ! -d "${SNAPSHOT_DIR}" ]]; then
        log_error "Snapshot directory not found: ${SNAPSHOT_DIR}"
        exit 1
    fi

    if [[ ! -f "${SNAPSHOT_DIR}/helm-release.json" ]]; then
        log_error "Required file missing from snapshot: helm-release.json"
        log_error "This does not look like a valid upgrade snapshot."
        exit 1
    fi

    if [[ ! -f "${SNAPSHOT_DIR}/kafka-cr.yaml" ]]; then
        log_error "Required file missing from snapshot: kafka-cr.yaml"
        exit 1
    fi

    log_ok "Snapshot directory: ${SNAPSHOT_DIR}"

    # Extract version info from UPGRADE-MANIFEST.env if present
    if [[ -f "${SNAPSHOT_DIR}/UPGRADE-MANIFEST.env" ]]; then
        # shellcheck source=/dev/null
        source "${SNAPSHOT_DIR}/UPGRADE-MANIFEST.env"
        SNAPSHOT_FROM_STRIMZI="${FROM_STRIMZI_VERSION:-}"
        SNAPSHOT_TO_STRIMZI="${TO_STRIMZI_VERSION:-}"
        SNAPSHOT_FROM_KAFKA="${FROM_KAFKA_VERSION:-}"
        log_ok "UPGRADE-MANIFEST.env read (from Strimzi ${SNAPSHOT_FROM_STRIMZI}, to ${SNAPSHOT_TO_STRIMZI})"
    else
        log_warn "No UPGRADE-MANIFEST.env in snapshot — version info will be extracted from helm-release.json"
    fi

    # Extract helm revision from snapshot
    SNAPSHOT_HELM_REVISION=$(python3 -c "
import sys, json
with open('${SNAPSHOT_DIR}/helm-release.json') as f:
    releases = json.load(f)
for r in releases:
    if r.get('name') == '${HELM_RELEASE}':
        print(r.get('revision', ''))
        break
" 2>/dev/null) || true

    if [[ -z "${SNAPSHOT_HELM_REVISION}" ]]; then
        log_error "Could not extract helm revision from helm-release.json"
        log_error "File contents:"
        cat "${SNAPSHOT_DIR}/helm-release.json" 2>&1 | tee -a "${LOG_FILE}" || true
        exit 1
    fi
    log_ok "Helm revision at snapshot: ${SNAPSHOT_HELM_REVISION}"

    # Extract metadataVersion from snapshot kafka-cr.yaml
    SNAPSHOT_META_VERSION=$(python3 -c "
import sys
# Simple YAML grep — avoids yaml dep requirement
with open('${SNAPSHOT_DIR}/kafka-cr.yaml') as f:
    for line in f:
        stripped = line.strip()
        if stripped.startswith('metadataVersion:'):
            val = stripped.split(':', 1)[1].strip().strip('\"').strip(\"'\")
            print(val)
            break
" 2>/dev/null) || true

    if [[ -z "${SNAPSHOT_META_VERSION}" ]]; then
        log_warn "Could not extract metadataVersion from snapshot kafka-cr.yaml"
        log_warn "metadataVersion will NOT be restored"
    else
        log_ok "Snapshot metadataVersion: ${SNAPSHOT_META_VERSION}"
    fi

    # Capture current live kafka.version (for the warning message)
    CURRENT_KAFKA_VERSION=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
        -n "${KAFKA_NAMESPACE}" \
        -o jsonpath='{.spec.kafka.version}' 2>/dev/null || echo "unknown")
    log_info "Current live kafka.version: ${CURRENT_KAFKA_VERSION} (will NOT be changed)"
}

# =============================================================================
# Step 2 — Confirm rollback plan with user
# =============================================================================

confirm_rollback() {
    log_step "Step 2 — Rollback Plan"

    echo ""
    echo "  ┌────────────────────────────────────────────────────────────────────┐"
    echo "  │  ROLLBACK PLAN                                                     │"
    echo "  ├────────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                    │"
    echo "  │  Snapshot dir:    ${SNAPSHOT_DIR}"
    echo "  │  Helm release:    ${HELM_RELEASE} (namespace: ${KAFKA_NAMESPACE})"
    echo "  │  Rollback to:     Helm revision ${SNAPSHOT_HELM_REVISION}"
    if [[ -n "${SNAPSHOT_FROM_STRIMZI}" ]]; then
        echo "  │  Strimzi:         ${SNAPSHOT_TO_STRIMZI:-current} → ${SNAPSHOT_FROM_STRIMZI}"
    fi
    echo "  │                                                                    │"
    if [[ -n "${SNAPSHOT_META_VERSION}" ]]; then
        echo "  │  metadataVersion: will be restored to: ${SNAPSHOT_META_VERSION}"
    fi
    echo "  │                                                                    │"
    echo "  │  ⚠  Kafka broker version (${CURRENT_KAFKA_VERSION}) will NOT be changed.   │"
    echo "  │     Kafka does not support broker version downgrade.               │"
    echo "  │     Topic data is SAFE.                                            │"
    echo "  │                                                                    │"
    echo "  └────────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ "${FORCE}" == "true" ]]; then
        log_info "Skipping confirmation prompt (--force)"
        return
    fi

    local answer
    read -r -p "  Type 'yes' to proceed with rollback, anything else to abort: " answer
    if [[ "${answer}" != "yes" ]]; then
        echo ""
        log_info "Aborted by user."
        exit 0
    fi
    echo ""
    log_info "User confirmed rollback"
}

# =============================================================================
# Step 3 — Roll back Strimzi operator via helm rollback
# =============================================================================

rollback_operator() {
    log_step "Step 3 — Rolling Back Strimzi Operator (Helm)"

    log_info "helm rollback ${HELM_RELEASE} ${SNAPSHOT_HELM_REVISION} -n ${KAFKA_NAMESPACE}"

    if $HELM_BIN rollback "${HELM_RELEASE}" "${SNAPSHOT_HELM_REVISION}" \
        -n "${KAFKA_NAMESPACE}" \
        --wait \
        --timeout=3m \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Helm rollback completed"
    else
        log_error "Helm rollback failed"
        log_error "Current helm release state:"
        $HELM_BIN list -n "${KAFKA_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || true
        exit 1
    fi

    log_info "Waiting for old operator pod to become Ready (${OPERATOR_READY_TIMEOUT}s)..."
    if kubectl rollout status deployment/strimzi-cluster-operator \
        -n "${KAFKA_NAMESPACE}" \
        --timeout="${OPERATOR_READY_TIMEOUT}s" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Operator is Ready after rollback"
    else
        log_error "Operator pod did not become Ready within ${OPERATOR_READY_TIMEOUT}s"
        kubectl describe pods -n "${KAFKA_NAMESPACE}" \
            -l name=strimzi-cluster-operator 2>&1 | tee -a "${LOG_FILE}" || true
        exit 1
    fi
}

# =============================================================================
# Step 4 — Restore Kafka CR metadataVersion from snapshot
# =============================================================================

restore_kafka_cr_metadata() {
    log_step "Step 4 — Restoring Kafka CR metadataVersion"

    # Always emit this data-safety warning
    log_warn "DATA SAFETY: Kafka broker version (${CURRENT_KAFKA_VERSION}) is NOT being changed."
    log_warn "             Kafka does not support broker version downgrade — topic data is preserved."

    if [[ -z "${SNAPSHOT_META_VERSION}" ]]; then
        log_warn "No snapshot metadataVersion found — skipping metadataVersion patch."
        log_warn "The operator may log reconciliation warnings until the Kafka CR is manually updated."
        return
    fi

    log_info "Patching Kafka CR metadataVersion → ${SNAPSHOT_META_VERSION}"

    kubectl patch kafka "${KAFKA_CLUSTER_NAME}" \
        -n "${KAFKA_NAMESPACE}" \
        --type=merge \
        -p "{\"spec\":{\"kafka\":{\"metadataVersion\":\"${SNAPSHOT_META_VERSION}\"}}}" \
        2>&1 | tee -a "${LOG_FILE}"

    log_ok "Kafka CR metadataVersion restored to: ${SNAPSHOT_META_VERSION}"
    log_ok "Kafka broker version remains at: ${CURRENT_KAFKA_VERSION} (unchanged, data safe)"
}

# =============================================================================
# Step 5 — Wait for Kafka cluster to stabilize after rollback
# =============================================================================

wait_for_kafka_stable() {
    log_step "Step 5 — Waiting for Kafka Cluster to Stabilize"

    log_info "Polling Kafka CR Ready condition (timeout: ${KAFKA_STABLE_TIMEOUT}s)..."

    local elapsed=0
    local interval=15

    while (( elapsed < KAFKA_STABLE_TIMEOUT )); do
        local ready
        ready=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
            -n "${KAFKA_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || echo "")

        if [[ "${ready}" == "True" ]]; then
            log_ok "Kafka CR is Ready (${elapsed}s)"
            break
        fi

        local reason
        reason=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
            -n "${KAFKA_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' \
            2>/dev/null || echo "")

        log_info "  Waiting for Kafka Ready... (${elapsed}s/${KAFKA_STABLE_TIMEOUT}s) ${reason:+— $reason}"
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    if (( elapsed >= KAFKA_STABLE_TIMEOUT )); then
        log_warn "Kafka CR did not reach Ready within ${KAFKA_STABLE_TIMEOUT}s after rollback."
        log_warn "This may resolve on its own — the old operator may still be reconciling."
    fi

    # Verify all broker pods are Running
    log_info "Checking broker pod status..."
    local running_count
    running_count=$(kubectl get pods -n "${KAFKA_NAMESPACE}" \
        -l "strimzi.io/component-type=kafka" \
        --field-selector=status.phase=Running \
        --no-headers 2>/dev/null | wc -l | tr -d ' ') || running_count=0

    if [[ "${running_count}" -ge 3 ]]; then
        log_ok "All ${running_count} broker pod(s) Running"
    else
        log_warn "Only ${running_count}/3 broker pods are Running — cluster may need time to stabilize"
        kubectl get pods -n "${KAFKA_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || true
    fi
}

# =============================================================================
# Rollback Summary
# =============================================================================

print_summary() {
    log_step "Rollback Complete"
    echo ""
    box "Strimzi Operator Rollback Successful!"
    echo ""

    if [[ -n "${SNAPSHOT_FROM_STRIMZI}" ]]; then
        log_ok "Strimzi rolled back:  ${SNAPSHOT_TO_STRIMZI:-?} → ${SNAPSHOT_FROM_STRIMZI}"
    fi
    log_ok "Helm revision:        ${SNAPSHOT_HELM_REVISION}"
    if [[ -n "${SNAPSHOT_META_VERSION}" ]]; then
        log_ok "metadataVersion:      restored to ${SNAPSHOT_META_VERSION}"
    fi

    echo ""
    log_warn "Kafka broker version:  ${CURRENT_KAFKA_VERSION} (unchanged — broker downgrade not supported)"
    log_warn "Topic data:            preserved — no data was modified during rollback"
    echo ""
    echo "  Bootstrap address (unchanged):"
    echo "    kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
    echo ""
    echo "  Useful commands:"
    echo "    kubectl get pods -n ${KAFKA_NAMESPACE}"
    echo "    kubectl get kafka ${KAFKA_CLUSTER_NAME} -n ${KAFKA_NAMESPACE} -o yaml | grep -A10 'status:'"
    echo "    ${HELM_BIN} history ${HELM_RELEASE} -n ${KAFKA_NAMESPACE}"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --snapshot-dir)
                SNAPSHOT_DIR="$2"
                shift 2
                ;;
            --namespace)
                KAFKA_NAMESPACE="$2"
                shift 2
                ;;
            --kubeconfig)
                KUBECONFIG="$2"
                shift 2
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            -h|--help)
                cat << 'HELP'
Usage: sudo ./rollback-kafka.sh [OPTIONS]

Required:
  --snapshot-dir PATH     Path to snapshot directory created by upgrade-kafka.sh
                          (e.g. /var/log/k3s-install/kafka-snapshots/20260712T100000Z)

Optional:
  --namespace NAME        Kafka namespace (default: kafka)
  --kubeconfig PATH       Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)
  --force                 Skip confirmation prompt (for automated use)
  -h, --help              Show this help

Examples:
  sudo ./rollback-kafka.sh \
    --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z

  sudo ./rollback-kafka.sh \
    --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z \
    --force

DATA SAFETY:
  This script rolls back the STRIMZI OPERATOR only (via helm rollback).
  The Kafka broker version is NOT downgraded — Kafka does not support
  broker version downgrade once data is written in the new format.
  Topic data is always preserved.

Available snapshots:
  ls -lt /var/log/k3s-install/kafka-snapshots/
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
    validate_snapshot
    confirm_rollback
    rollback_operator
    restore_kafka_cr_metadata
    wait_for_kafka_stable
    print_summary

    log_info "Kafka operator rollback finished"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
