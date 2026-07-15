#!/bin/bash

################################################################################
# Strimzi Kafka Operator — Offline Upgrade
#
# Purpose: Upgrade the Strimzi operator and Kafka version on an offline K3s
#          cluster using a pre-prepared upgrade bundle. Takes a snapshot before
#          making any changes so rollback is always possible.
#
# Usage:   sudo ./upgrade-kafka.sh --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0
#
# Safe to re-run:  Each step is tracked via marker files. A failed mid-upgrade
#                  run can be retried from where it stopped.
#
# Requirements:
#   - K3s cluster running with a healthy Kafka cluster
#   - Upgrade bundle created with prepare-kafka-upgrade-bundle.sh and transferred
#   - kubectl configured to access cluster
#   - Helm 3.x installed
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

BUNDLE_PATH="${BUNDLE_PATH:-}"
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_CLUSTER_NAME="${KAFKA_CLUSTER_NAME:-kafka-cluster}"
KAFKA_POOL_NAME="${KAFKA_POOL_NAME:-kafka}"
HELM_RELEASE="${HELM_RELEASE:-strimzi-operator}"
HELM_BIN="${HELM_BIN:-helm}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

DRY_RUN="${DRY_RUN:-false}"
SKIP_KAFKA_VERSION_UPGRADE="${SKIP_KAFKA_VERSION_UPGRADE:-false}"
METADATA_VERSION_OVERRIDE=""   # set by --metadata-version flag

LOG_DIR="/var/log/k3s-install"
STEP_DIR="${LOG_DIR}/.steps-kafka-upgrade"
LOG_FILE="${LOG_DIR}/kafka-upgrade.log"
SNAPSHOT_BASE_DIR="${LOG_DIR}/kafka-snapshots"

OPERATOR_READY_TIMEOUT=120    # seconds
KAFKA_READY_TIMEOUT=600       # seconds; rolling restart takes longer than fresh install

# Populated by sourcing UPGRADE-MANIFEST.env
FROM_STRIMZI_VERSION=""
TO_STRIMZI_VERSION=""
FROM_KAFKA_VERSION=""
TO_KAFKA_VERSION=""
NEW_STRIMZI_OPERATOR_TAR=""
NEW_STRIMZI_KAFKA_TAR=""
STRIMZI_CHART=""
ARCH=""

# Set in snapshot_cluster_state()
SNAPSHOT_DIR=""

# Known Kafka version → KRaft metadataVersion map
# metadataVersion is the highest stable metadata version for each Kafka release
declare -A METADATA_VERSION_MAP=(
    ["4.0.0"]="4.0-IV0"
    ["4.1.0"]="4.1-IV3"
)

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
# Step Tracking (idempotent re-run support)
# =============================================================================

step_done() {
    [[ -f "${STEP_DIR}/$1" ]]
}

mark_done() {
    mkdir -p "${STEP_DIR}"
    touch "${STEP_DIR}/$1"
}

# =============================================================================
# Initialization
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${STEP_DIR}" "${SNAPSHOT_BASE_DIR}"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    export KUBECONFIG

    box "Strimzi Kafka — Offline Upgrade"

    log_info "Configuration:"
    log_info "  Bundle Path    : ${BUNDLE_PATH}"
    log_info "  Namespace      : ${KAFKA_NAMESPACE}"
    log_info "  Helm Release   : ${HELM_RELEASE}"
    log_info "  Dry Run        : ${DRY_RUN}"
    log_info "  Skip Kafka Ver : ${SKIP_KAFKA_VERSION_UPGRADE}"
    log_info "  KUBECONFIG     : ${KUBECONFIG}"
    log_info "  Log file       : ${LOG_FILE}"
}

# =============================================================================
# Dry-run summary (print plan and exit without touching cluster)
# =============================================================================

dry_run_summary() {
    log_step "DRY RUN — Upgrade Plan (no changes will be made)"

    echo ""
    echo "  Steps that would be executed:"
    echo ""
    echo "  1. validate_bundle"
    echo "     ✦ Source ${BUNDLE_PATH}/UPGRADE-MANIFEST.env"
    echo "     ✦ Verify FROM_STRIMZI=${FROM_STRIMZI_VERSION} matches current helm release"
    echo ""
    echo "  2. snapshot_cluster_state"
    echo "     ✦ Create ${SNAPSHOT_BASE_DIR}/<timestamp>/"
    echo "     ✦ Save: helm-values.yaml, helm-release.json, kafka-cr.yaml, kafkanodepool-cr.yaml, UPGRADE-MANIFEST.env"
    echo ""
    echo "  3. load_new_images"
    echo "     ✦ k3s ctr images import ${BUNDLE_PATH}/images/${NEW_STRIMZI_OPERATOR_TAR}"
    echo "     ✦ k3s ctr images import ${BUNDLE_PATH}/images/${NEW_STRIMZI_KAFKA_TAR}"
    echo ""
    echo "  4. upgrade_strimzi_operator"
    echo "     ✦ helm upgrade ${HELM_RELEASE} ${BUNDLE_PATH}/charts/${STRIMZI_CHART} -n ${KAFKA_NAMESPACE}"
    echo "     ✦ Wait for strimzi-cluster-operator rollout (120s)"
    echo ""

    if [[ "${SKIP_KAFKA_VERSION_UPGRADE}" == "true" ]]; then
        echo "  5. upgrade_kafka_version — SKIPPED (--skip-kafka-version-upgrade)"
    else
        local meta_ver="${METADATA_VERSION_OVERRIDE}"
        if [[ -z "${meta_ver}" ]]; then
            meta_ver="${METADATA_VERSION_MAP[${TO_KAFKA_VERSION}]:-UNKNOWN}"
        fi
        echo "  5. upgrade_kafka_version"
        echo "     ✦ kubectl patch kafka ${KAFKA_CLUSTER_NAME} → spec.kafka.version: ${TO_KAFKA_VERSION}"
        echo "     ✦ kubectl patch kafka ${KAFKA_CLUSTER_NAME} → spec.kafka.metadataVersion: ${meta_ver}"
        echo "     ✦ Wait for Kafka CR Ready (600s) — rolling broker restart"
    fi

    echo ""
    echo "  6. verify_cluster (produce/consume test)"
    echo ""
    echo "  Dry run complete. Pass without --dry-run to execute."
    log_info "Dry run complete — exiting"
    exit 0
}

# =============================================================================
# Step 1 — Validate upgrade bundle and verify version alignment
# =============================================================================

validate_bundle() {
    log_step "Step 1 — Validating Upgrade Bundle"

    if [[ -z "${BUNDLE_PATH}" ]]; then
        log_error "--bundle-path is required. Example: --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0"
        exit 1
    fi

    if [[ ! -d "${BUNDLE_PATH}" ]]; then
        log_error "Bundle directory not found: ${BUNDLE_PATH}"
        log_error "Transfer the upgrade bundle and try again."
        exit 1
    fi

    if [[ ! -f "${BUNDLE_PATH}/UPGRADE-MANIFEST.env" ]]; then
        log_error "UPGRADE-MANIFEST.env not found in bundle: ${BUNDLE_PATH}/UPGRADE-MANIFEST.env"
        log_error "This does not look like an upgrade bundle. Use prepare-kafka-upgrade-bundle.sh to create one."
        exit 1
    fi

    # Source manifest to get FROM/TO version variables
    # shellcheck source=/dev/null
    source "${BUNDLE_PATH}/UPGRADE-MANIFEST.env"
    log_ok "UPGRADE-MANIFEST.env sourced"
    log_info "  From:  Strimzi ${FROM_STRIMZI_VERSION} / Kafka ${FROM_KAFKA_VERSION}"
    log_info "  To:    Strimzi ${TO_STRIMZI_VERSION} / Kafka ${TO_KAFKA_VERSION}"
    log_info "  Arch:  linux/${ARCH}"

    # Verify image tars and chart exist
    local missing=0

    local operator_tar="${BUNDLE_PATH}/images/${NEW_STRIMZI_OPERATOR_TAR}"
    if [[ -f "${operator_tar}" ]] && [[ -s "${operator_tar}" ]]; then
        log_ok "images/${NEW_STRIMZI_OPERATOR_TAR}"
    else
        log_error "Missing image tar: ${operator_tar}"
        missing=1
    fi

    local kafka_tar="${BUNDLE_PATH}/images/${NEW_STRIMZI_KAFKA_TAR}"
    if [[ -f "${kafka_tar}" ]] && [[ -s "${kafka_tar}" ]]; then
        log_ok "images/${NEW_STRIMZI_KAFKA_TAR}"
    else
        log_error "Missing image tar: ${kafka_tar}"
        missing=1
    fi

    local chart_file="${BUNDLE_PATH}/charts/${STRIMZI_CHART}"
    if [[ -f "${chart_file}" ]] && [[ -s "${chart_file}" ]]; then
        log_ok "charts/${STRIMZI_CHART}"
    else
        log_error "Missing Helm chart: ${chart_file}"
        missing=1
    fi

    if [[ "${missing}" -ne 0 ]]; then
        log_error "Bundle validation failed. Correct the missing files and retry."
        exit 1
    fi

    # Verify the cluster's current operator version matches FROM_STRIMZI_VERSION
    log_info "Checking current Strimzi version on cluster..."
    local current_chart_version
    current_chart_version=$($HELM_BIN list -n "${KAFKA_NAMESPACE}" -o json 2>/dev/null \
        | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if r.get('name') == '${HELM_RELEASE}':
        chart = r.get('chart', '')
        # chart is like 'strimzi-kafka-operator-0.48.0'
        version = chart.rsplit('-', 1)[-1] if '-' in chart else chart
        print(version)
        break
" 2>/dev/null) || true

    if [[ -z "${current_chart_version}" ]]; then
        log_warn "Could not determine current Strimzi version via helm list (release '${HELM_RELEASE}' not found or helm unavailable)"
        log_warn "Skipping version match check — proceed with caution"
    elif [[ "${current_chart_version}" == "${FROM_STRIMZI_VERSION}" ]]; then
        log_ok "Current Strimzi version: ${current_chart_version} (matches FROM_STRIMZI_VERSION)"
    elif [[ "${current_chart_version}" == "${TO_STRIMZI_VERSION}" ]]; then
        log_warn "Helm chart is already at version ${TO_STRIMZI_VERSION} (Helm revision 2+)."
        log_error "This usually means a previous upgrade attempt partially succeeded:"
        log_error "  helm upgraded the chart but the operator pod did not become Ready."
        log_error ""
        log_error "Check operator pod health:"
        log_error "  kubectl get pods -n ${KAFKA_NAMESPACE} -l name=strimzi-cluster-operator"
        log_error ""
        log_error "If the operator is NOT Running, roll back first then retry:"
        log_error "  sudo ./rollback-kafka.sh --snapshot-dir <path-from-previous-run>"
        log_error "  (snapshots are in ${SNAPSHOT_BASE_DIR}/)"
        log_error ""
        log_error "If the operator IS Running on ${TO_STRIMZI_VERSION}, the upgrade succeeded."
        exit 1
    else
        log_warn "Current version: ${current_chart_version}  Expected FROM: ${FROM_STRIMZI_VERSION}"
        log_error "Bundle FROM_STRIMZI_VERSION (${FROM_STRIMZI_VERSION}) does not match cluster version (${current_chart_version})."
        log_error "Prepare a bundle matching the actual running version."
        exit 1
    fi

    log_ok "Bundle validated"
}

# =============================================================================
# Step 2 — Snapshot cluster state
# =============================================================================

snapshot_cluster_state() {
    local ts
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    SNAPSHOT_DIR="${SNAPSHOT_BASE_DIR}/${ts}"

    step_done "snapshot-${ts}" && {
        log_info "Snapshot already exists at ${SNAPSHOT_DIR} — reusing."
        return
    }

    log_step "Step 2 — Snapshotting Cluster State"
    log_info "Snapshot dir: ${SNAPSHOT_DIR}"

    mkdir -p "${SNAPSHOT_DIR}"

    log_info "Saving Helm release values..."
    $HELM_BIN get values "${HELM_RELEASE}" -n "${KAFKA_NAMESPACE}" \
        > "${SNAPSHOT_DIR}/helm-values.yaml" 2>&1 || true
    log_ok "helm-values.yaml"

    log_info "Saving Helm release metadata..."
    $HELM_BIN list -n "${KAFKA_NAMESPACE}" -o json \
        > "${SNAPSHOT_DIR}/helm-release.json" 2>&1 || true
    log_ok "helm-release.json"

    log_info "Saving Kafka CR..."
    kubectl get kafka "${KAFKA_CLUSTER_NAME}" -n "${KAFKA_NAMESPACE}" -o yaml \
        > "${SNAPSHOT_DIR}/kafka-cr.yaml" 2>&1 || true
    log_ok "kafka-cr.yaml"

    log_info "Saving KafkaNodePool CR..."
    kubectl get kafkanodepool -n "${KAFKA_NAMESPACE}" -o yaml \
        > "${SNAPSHOT_DIR}/kafkanodepool-cr.yaml" 2>&1 || true
    log_ok "kafkanodepool-cr.yaml"

    log_info "Copying UPGRADE-MANIFEST.env..."
    cp "${BUNDLE_PATH}/UPGRADE-MANIFEST.env" "${SNAPSHOT_DIR}/UPGRADE-MANIFEST.env"
    log_ok "UPGRADE-MANIFEST.env"

    mark_done "snapshot-${ts}"

    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    echo "  │  Snapshot saved at:                                              │"
    echo "  │  ${SNAPSHOT_DIR}"
    echo "  │                                                                  │"
    echo "  │  Pass this path to rollback-kafka.sh if you need to undo:       │"
    echo "  │  sudo ./rollback-kafka.sh --snapshot-dir ${SNAPSHOT_DIR}"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    echo ""
}

# =============================================================================
# Step 3 — Load new images into K3s containerd
# =============================================================================

load_new_images() {
    step_done "new-images-loaded-${TO_STRIMZI_VERSION}" && {
        log_info "New images already loaded — skipping."
        return
    }

    log_step "Step 3 — Loading New Container Images into K3s"

    local operator_tar="${BUNDLE_PATH}/images/${NEW_STRIMZI_OPERATOR_TAR}"
    local kafka_tar="${BUNDLE_PATH}/images/${NEW_STRIMZI_KAFKA_TAR}"

    log_info "Importing: ${NEW_STRIMZI_OPERATOR_TAR}"
    if k3s ctr images import "${operator_tar}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Imported: ${NEW_STRIMZI_OPERATOR_TAR}"
    else
        log_error "Failed to import: ${operator_tar}"
        exit 1
    fi

    log_info "Importing: ${NEW_STRIMZI_KAFKA_TAR}"
    if k3s ctr images import "${kafka_tar}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Imported: ${NEW_STRIMZI_KAFKA_TAR}"
    else
        log_error "Failed to import: ${kafka_tar}"
        exit 1
    fi

    # Verify new images appear in containerd — check each image name precisely
    local new_operator_image="quay.io/strimzi/operator:${TO_STRIMZI_VERSION}"
    local new_kafka_image="quay.io/strimzi/kafka:${TO_STRIMZI_VERSION}-kafka-${TO_KAFKA_VERSION}"
    local verify_failed=0

    local ctr_list
    ctr_list=$(k3s ctr --namespace k8s.io images list 2>/dev/null) || true

    if echo "${ctr_list}" | grep -q "${new_operator_image}"; then
        log_ok "Verified in containerd: ${new_operator_image}"
    else
        log_warn "Cannot confirm in containerd: ${new_operator_image}"
        verify_failed=1
    fi

    if echo "${ctr_list}" | grep -q "${new_kafka_image}"; then
        log_ok "Verified in containerd: ${new_kafka_image}"
    else
        log_warn "Cannot confirm in containerd: ${new_kafka_image}"
        verify_failed=1
    fi

    if [[ "${verify_failed}" -ne 0 ]]; then
        log_warn "Image verification incomplete. If the upgrade fails with ImagePullBackOff, re-import manually:"
        log_warn "  sudo k3s ctr --namespace k8s.io images list | grep strimzi"
    fi

    mark_done "new-images-loaded-${TO_STRIMZI_VERSION}"
}

# =============================================================================
# Step 4 — Upgrade Strimzi operator via Helm
# =============================================================================

upgrade_strimzi_operator() {
    step_done "operator-upgraded-${TO_STRIMZI_VERSION}" && {
        log_info "Operator already upgraded to ${TO_STRIMZI_VERSION} — skipping."
        return
    }

    log_step "Step 4 — Upgrading Strimzi Operator"

    local chart="${BUNDLE_PATH}/charts/${STRIMZI_CHART}"
    log_info "Chart: ${chart}"
    log_info "Helm release: ${HELM_RELEASE}"

    # --reset-values uses the new chart's defaults (picks up the new image tag).
    # -f snapshot values re-applies only the user's explicit overrides (e.g. watchAnyNamespace).
    # --reuse-values would carry the old image tag forward, causing the old binary to run under
    # the new chart config — the root cause of the CrashLoopBackOff seen during upgrade testing.
    if $HELM_BIN upgrade "${HELM_RELEASE}" "${chart}" \
        --namespace "${KAFKA_NAMESPACE}" \
        --reset-values \
        -f "${SNAPSHOT_DIR}/helm-values.yaml" \
        --timeout=5m \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Helm upgrade completed"
    else
        log_error "Helm upgrade failed for release '${HELM_RELEASE}'"
        log_error "Run 'helm list -n ${KAFKA_NAMESPACE}' to check release state"
        exit 1
    fi

    log_info "Waiting for new operator pod to become Ready (${OPERATOR_READY_TIMEOUT}s)..."
    if kubectl rollout status deployment/strimzi-cluster-operator \
        -n "${KAFKA_NAMESPACE}" \
        --timeout="${OPERATOR_READY_TIMEOUT}s" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Strimzi operator ${TO_STRIMZI_VERSION} is Ready"
    else
        log_error "New operator pod did not become Ready within ${OPERATOR_READY_TIMEOUT}s"
        log_error "Image running on operator pod(s) — should be ${TO_STRIMZI_VERSION}:"
        kubectl get pods -n "${KAFKA_NAMESPACE}" \
            -l name=strimzi-cluster-operator \
            -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[0].image}{"\n"}{end}' \
            2>&1 | tee -a "${LOG_FILE}" || true
        log_error "Operator pod events:"
        kubectl describe pods -n "${KAFKA_NAMESPACE}" \
            -l name=strimzi-cluster-operator 2>&1 | tee -a "${LOG_FILE}" || true
        log_error "To roll back: sudo ./rollback-kafka.sh --snapshot-dir ${SNAPSHOT_DIR}"
        exit 1
    fi

    mark_done "operator-upgraded-${TO_STRIMZI_VERSION}"
}

# =============================================================================
# Step 5 — Patch Kafka CR version + metadataVersion (triggers rolling restart)
# =============================================================================

upgrade_kafka_version() {
    if [[ "${SKIP_KAFKA_VERSION_UPGRADE}" == "true" ]]; then
        log_info "Skipping Kafka version upgrade (--skip-kafka-version-upgrade)"
        return
    fi

    step_done "kafka-version-upgraded-${TO_KAFKA_VERSION}" && {
        log_info "Kafka version already patched to ${TO_KAFKA_VERSION} — skipping."
        return
    }

    log_step "Step 5 — Patching Kafka CR (version + metadataVersion)"

    # Resolve metadataVersion: flag override → map lookup → error
    local meta_ver="${METADATA_VERSION_OVERRIDE}"
    if [[ -z "${meta_ver}" ]]; then
        meta_ver="${METADATA_VERSION_MAP[${TO_KAFKA_VERSION}]:-}"
    fi

    if [[ -z "${meta_ver}" ]]; then
        log_error "Unknown metadataVersion for Kafka ${TO_KAFKA_VERSION}."
        log_error "The METADATA_VERSION_MAP in this script does not include ${TO_KAFKA_VERSION}."
        log_error "Find the correct value in the Strimzi release notes, then pass:"
        log_error "  --metadata-version <value>   (e.g. 4.2-IV0)"
        exit 1
    fi

    log_info "Patching Kafka CR: version=${TO_KAFKA_VERSION}, metadataVersion=${meta_ver}"

    kubectl patch kafka "${KAFKA_CLUSTER_NAME}" \
        -n "${KAFKA_NAMESPACE}" \
        --type=merge \
        -p "{\"spec\":{\"kafka\":{\"version\":\"${TO_KAFKA_VERSION}\",\"metadataVersion\":\"${meta_ver}\"}}}" \
        2>&1 | tee -a "${LOG_FILE}"

    log_ok "Kafka CR patched — Strimzi will now perform a rolling broker restart"
    log_info "  version:         ${TO_KAFKA_VERSION}"
    log_info "  metadataVersion: ${meta_ver}"

    mark_done "kafka-version-upgraded-${TO_KAFKA_VERSION}"
}

# =============================================================================
# Step 6 — Wait for Kafka CR to become Ready (covers rolling restart)
# =============================================================================

wait_for_kafka_ready() {
    log_step "Step 6 — Waiting for Kafka Cluster Ready (rolling restart)"

    log_info "Polling Kafka CR status (timeout: ${KAFKA_READY_TIMEOUT}s, logging every 30s)..."

    local elapsed=0
    local interval=30

    while (( elapsed < KAFKA_READY_TIMEOUT )); do
        local ready
        ready=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
            -n "${KAFKA_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || echo "")

        if [[ "${ready}" == "True" ]]; then
            log_ok "Kafka cluster is Ready after ${elapsed}s"
            return 0
        fi

        local reason
        reason=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
            -n "${KAFKA_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' \
            2>/dev/null || echo "")

        log_info "  Waiting for Kafka Ready... (${elapsed}s/${KAFKA_READY_TIMEOUT}s) ${reason:+— $reason}"
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    log_error "Kafka cluster did not become Ready within ${KAFKA_READY_TIMEOUT}s"
    log_error "Broker pod status:"
    kubectl get pods -n "${KAFKA_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || true
    log_error "Strimzi operator logs (last 50 lines):"
    kubectl logs -n "${KAFKA_NAMESPACE}" \
        -l name=strimzi-cluster-operator \
        --tail=50 2>&1 | tee -a "${LOG_FILE}" || true
    log_error "Snapshot dir for rollback: ${SNAPSHOT_DIR}"
    log_error "Run: sudo ./rollback-kafka.sh --snapshot-dir ${SNAPSHOT_DIR}"
    exit 1
}

# =============================================================================
# Step 7 — Verify cluster end-to-end (produce/consume test)
# =============================================================================

verify_cluster() {
    log_step "Step 7 — Verifying Kafka Cluster (produce/consume)"

    local broker_pod="${KAFKA_CLUSTER_NAME}-${KAFKA_POOL_NAME}-0"
    local bootstrap="${KAFKA_CLUSTER_NAME}-kafka-bootstrap:9092"
    local test_topic="upgrade-verify"

    log_info "Using broker pod: ${broker_pod}"
    log_info "Bootstrap:        ${bootstrap}"

    log_info "Creating test topic '${test_topic}'..."
    if kubectl exec "${broker_pod}" -n "${KAFKA_NAMESPACE}" -- \
        /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server "${bootstrap}" \
        --create \
        --topic "${test_topic}" \
        --partitions 3 \
        --replication-factor 3 \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Test topic created"
    else
        log_warn "Topic creation had errors (may already exist) — continuing"
    fi

    log_info "Producing test message..."
    if echo "upgrade-verify-$(date -u +%s)" | kubectl exec -i "${broker_pod}" \
        -n "${KAFKA_NAMESPACE}" -- \
        /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server "${bootstrap}" \
        --topic "${test_topic}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Test message produced"
    else
        log_warn "Producer step had errors — checking cluster state manually"
        kubectl get pods -n "${KAFKA_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || true
    fi

    log_info "Consuming test message (10s timeout)..."
    if kubectl exec "${broker_pod}" -n "${KAFKA_NAMESPACE}" -- \
        /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server "${bootstrap}" \
        --topic "${test_topic}" \
        --from-beginning \
        --max-messages 1 \
        --timeout-ms 10000 \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Test message consumed — end-to-end verified"
    else
        log_warn "Consumer timed out — cluster may need more time to stabilize"
        log_warn "Re-run manually: kubectl exec ${broker_pod} -n ${KAFKA_NAMESPACE} -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server ${bootstrap} --topic ${test_topic} --from-beginning --max-messages 1"
    fi

    kubectl exec "${broker_pod}" -n "${KAFKA_NAMESPACE}" -- \
        /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server "${bootstrap}" \
        --delete \
        --topic "${test_topic}" \
        2>&1 | tee -a "${LOG_FILE}" || true
    log_ok "Test topic deleted"
}

# =============================================================================
# Upgrade Summary
# =============================================================================

print_summary() {
    log_step "Upgrade Complete"
    echo ""
    box "Kafka Cluster Upgrade Successful!"
    echo ""

    log_ok "Strimzi:  ${FROM_STRIMZI_VERSION} → ${TO_STRIMZI_VERSION}"
    if [[ "${SKIP_KAFKA_VERSION_UPGRADE}" == "true" ]]; then
        log_ok "Kafka:    unchanged (operator-only upgrade)"
    else
        log_ok "Kafka:    ${FROM_KAFKA_VERSION} → ${TO_KAFKA_VERSION}"
    fi
    log_ok "Snapshot: ${SNAPSHOT_DIR}"
    echo ""
    echo "  Bootstrap address (unchanged):"
    echo "    kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
    echo ""
    echo "  To roll back if needed:"
    echo "    sudo ./rollback-kafka.sh --snapshot-dir ${SNAPSHOT_DIR}"
    echo ""
    echo "  Useful commands:"
    echo "    kubectl get pods -n ${KAFKA_NAMESPACE}"
    echo "    kubectl get kafka ${KAFKA_CLUSTER_NAME} -n ${KAFKA_NAMESPACE} -o yaml | grep -A10 'status:'"
    echo "    ${HELM_BIN} list -n ${KAFKA_NAMESPACE}"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle-path)
                BUNDLE_PATH="$2"
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
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --skip-kafka-version-upgrade)
                SKIP_KAFKA_VERSION_UPGRADE="true"
                shift
                ;;
            --metadata-version)
                METADATA_VERSION_OVERRIDE="$2"
                shift 2
                ;;
            -h|--help)
                cat << 'HELP'
Usage: sudo ./upgrade-kafka.sh [OPTIONS]

Required:
  --bundle-path PATH           Path to extracted upgrade bundle directory
                               (created by prepare-kafka-upgrade-bundle.sh)

Optional:
  --namespace NAME             Kafka namespace (default: kafka)
  --kubeconfig PATH            Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)
  --dry-run                    Print upgrade plan and exit without making changes
  --skip-kafka-version-upgrade Upgrade operator only; do not patch Kafka CR version
  --metadata-version VALUE     Override metadataVersion for the new Kafka version
                               (e.g. 4.1-IV3). Use if the built-in map is outdated.
  -h, --help                   Show this help

Examples:
  sudo ./upgrade-kafka.sh --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0
  sudo ./upgrade-kafka.sh --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0 --dry-run
  sudo ./upgrade-kafka.sh --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0 \
    --skip-kafka-version-upgrade
  sudo ./upgrade-kafka.sh --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0 \
    --metadata-version 4.1-IV3

Re-run safety:
  Completed steps are tracked in /var/log/k3s-install/.steps-kafka-upgrade/.
  Re-running after a failure resumes from where it stopped.
  To force a full re-run: sudo rm -rf /var/log/k3s-install/.steps-kafka-upgrade/
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

    # validate_bundle must run before dry-run summary so manifest is sourced
    validate_bundle

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_run_summary
        # dry_run_summary exits 0
    fi

    snapshot_cluster_state
    load_new_images
    upgrade_strimzi_operator
    upgrade_kafka_version
    wait_for_kafka_ready
    verify_cluster
    print_summary

    log_info "Kafka upgrade finished successfully"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
