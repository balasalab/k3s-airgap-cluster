#!/bin/bash

################################################################################
# Percona MongoDB Operator — Offline Upgrade
#
# Purpose: Apply an offline upgrade bundle to a K3s cluster.
#          Upgrades the operator, CRDs, and/or MongoDB pod images.
#
# Usage:   sudo ./upgrade-mongodb-operator.sh \
#            --bundle /opt/upgrade-bundle-1.22.0.tar.gz
#
# Requirements:
#   - K3s cluster running (containerd runtime)
#   - Offline upgrade bundle from prepare-upgrade-bundle.sh
#   - kubectl and helm configured
#   - Root access (EUID=0)
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

BUNDLE_PATH=""
MONGODB_NAMESPACE="mongodb"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
DRY_RUN=false
FORCE=false
RESET_STEPS=false
HELM_BIN="${HELM_BIN:-helm}"
MONGODB_PAIRS_PATCHED=""   # space-separated pair indices that were actually applied

LOG_DIR="/var/log/k3s-install"
STEP_DIR="${LOG_DIR}/.steps"
LOG_FILE="${LOG_DIR}/mongodb-operator-upgrade.log"

WORK_DIR=""   # set by extract_bundle; cleaned on EXIT
SNAPSHOT_DIR=""

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
# Step Tracking — all markers MUST use "upgrade-" prefix (task 2.1)
# =============================================================================

step_done() {
    [[ -f "${STEP_DIR}/upgrade-$1" ]]
}

mark_done() {
    mkdir -p "${STEP_DIR}"
    touch "${STEP_DIR}/upgrade-$1"
}

# =============================================================================
# Argument Parsing (task 2.2)
# =============================================================================

parse_args() {
    if [[ $# -eq 0 ]]; then
        log_error "No arguments provided."
        echo "  → Run: sudo ./upgrade-mongodb-operator.sh --bundle /path/to/upgrade.tar.gz"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)       BUNDLE_PATH="$2";         shift 2 ;;
            --namespace)    MONGODB_NAMESPACE="$2";   shift 2 ;;
            --kubeconfig)   KUBECONFIG="$2";          shift 2 ;;
            --dry-run)      DRY_RUN=true;             shift ;;
            --force)        FORCE=true;               shift ;;
            --reset-steps)  RESET_STEPS=true;         shift ;;
            -h|--help)
                echo "Usage: sudo ./upgrade-mongodb-operator.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --bundle PATH        Path to upgrade bundle .tar.gz (required)"
                echo "  --namespace NAME     K8s namespace for operator (default: mongodb)"
                echo "  --kubeconfig PATH    Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)"
                echo "  --dry-run            Preview changes without applying them"
                echo "  --force              Bypass FROM_VERSION validation check"
                echo "  --reset-steps        Clear upgrade-* step markers for a clean retry"
                echo "  -h, --help           Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "  → Run: sudo ./upgrade-mongodb-operator.sh --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "${BUNDLE_PATH}" ]]; then
        log_error "--bundle is required."
        echo "  → Run: sudo ./upgrade-mongodb-operator.sh --bundle /path/to/upgrade.tar.gz"
        exit 1
    fi
}

# =============================================================================
# Initialization (task 2.3)
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${STEP_DIR}"

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}  ✘ ERROR: This script must be run as root (sudo)${NC}"
        exit 1
    fi

    export KUBECONFIG

    # --reset-steps: remove only upgrade-* markers, never install-script markers
    if [[ "${RESET_STEPS}" == "true" ]]; then
        log_info "Clearing upgrade step markers..."
        find "${STEP_DIR}" -name "upgrade-*" -delete 2>/dev/null || true
        log_ok "Step markers cleared"
    fi

    box "Percona MongoDB Operator — Offline Upgrade"

    log_info "Configuration:"
    log_info "  Bundle       : ${BUNDLE_PATH}"
    log_info "  Namespace    : ${MONGODB_NAMESPACE}"
    log_info "  KUBECONFIG   : ${KUBECONFIG}"
    log_info "  Dry-run      : ${DRY_RUN}"
    log_info "  Force        : ${FORCE}"
}

# =============================================================================
# Bundle Extraction (task 2.4)
# =============================================================================

extract_bundle() {
    log_step "Extracting Upgrade Bundle"

    if [[ ! -f "${BUNDLE_PATH}" ]]; then
        log_error "Bundle not found: ${BUNDLE_PATH}"
        echo "  → Verify the path and try again"
        exit 1
    fi

    WORK_DIR=$(mktemp -d)
    # Trap cleans ONLY the temp dir — step dir and logs must NOT be removed
    trap 'rm -rf "${WORK_DIR}"' EXIT

    log_info "  Extracting to: ${WORK_DIR}"
    tar -xzf "${BUNDLE_PATH}" -C "${WORK_DIR}" --strip-components=1 \
        2>&1 | tee -a "${LOG_FILE}"

    # Source MANIFEST.env
    if [[ ! -f "${WORK_DIR}/MANIFEST.env" ]]; then
        log_error "MANIFEST.env not found in bundle"
        echo "  → Re-prepare the bundle with prepare-upgrade-bundle.sh"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${WORK_DIR}/MANIFEST.env"

    log_ok "Bundle extracted and MANIFEST.env sourced"
    log_info "  Bundle type   : ${BUNDLE_TYPE:-unknown}"
    log_info "  Created       : ${BUNDLE_CREATED:-unknown}"
    log_info "  Architecture  : ${ARCH:-unknown}"
    log_info "  Images        : ${IMAGES_INCLUDED:-none}"
}

# =============================================================================
# Bundle Verification (task 2.5)
# =============================================================================

verify_bundle() {
    step_done "bundle-verified" && {
        log_info "Bundle already verified, skipping."
        return
    }

    log_step "Verifying Bundle Contents"

    # Confirm a required MANIFEST variable is set
    if [[ -z "${BUNDLE_TYPE:-}" ]]; then
        log_error "MANIFEST.env did not source correctly (BUNDLE_TYPE is unset)"
        echo "  → Re-prepare the bundle with prepare-upgrade-bundle.sh"
        exit 1
    fi

    # Check images tarball when images are expected
    if [[ -n "${IMAGES_INCLUDED:-}" ]]; then
        if [[ -f "${WORK_DIR}/images/${IMAGES_FILE}" ]]; then
            log_ok "images/${IMAGES_FILE}"
        else
            log_error "Missing image archive: images/${IMAGES_FILE}"
            echo "  → Re-prepare the bundle or use --full flag"
            exit 1
        fi
    fi

    # Check Helm chart when operator upgrade is expected
    if [[ "${UPGRADE_OPERATOR:-false}" == "true" ]]; then
        if [[ -f "${WORK_DIR}/helm-charts/${HELM_CHART}" ]]; then
            log_ok "helm-charts/${HELM_CHART}"
        else
            log_error "Missing Helm chart: helm-charts/${HELM_CHART}"
            echo "  → Re-prepare the bundle or use --full flag"
            exit 1
        fi
    fi

    mark_done "bundle-verified"
    log_ok "Bundle verification passed"
}

# =============================================================================
# Prerequisites Check (task 2.6)
# =============================================================================

check_prerequisites() {
    step_done "prerequisites-checked" && {
        log_info "Prerequisites already checked, skipping."
        return
    }

    log_step "Checking Prerequisites"

    if kubectl get nodes &>/dev/null; then
        log_ok "Kubernetes cluster accessible"
    else
        log_error "Cannot access Kubernetes cluster"
        echo "  → Check KUBECONFIG: ${KUBECONFIG}"
        exit 1
    fi

    if command -v helm &>/dev/null || [[ -f "/usr/local/bin/helm" ]]; then
        log_ok "Helm found"
    else
        log_error "Helm not found"
        exit 1
    fi

    if k3s ctr --version &>/dev/null; then
        log_ok "K3s containerd available"
    else
        log_error "K3s containerd not found"
        exit 1
    fi

    mark_done "prerequisites-checked"
}

# =============================================================================
# FROM_VERSION Validation (task 2.7)
# =============================================================================

validate_from_version() {
    log_step "Validating Installed Version"

    # Get installed chart version via helm list
    local helm_chart_field
    helm_chart_field=$(helm list --filter psmdb-operator -n "${MONGODB_NAMESPACE}" \
        --no-headers 2>/dev/null | awk '{print $9}') || true

    if [[ -z "${helm_chart_field}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warn "psmdb-operator not found in namespace '${MONGODB_NAMESPACE}' — skipping version check in dry-run mode"
            return
        fi
        log_error "psmdb-operator release not found in namespace '${MONGODB_NAMESPACE}'"
        echo "  → Run install-mongodb-operator.sh first; upgrade requires an existing installation"
        exit 1
    fi

    # Strip "psmdb-operator-" prefix to get the semver
    local installed_version
    installed_version=$(echo "${helm_chart_field}" | sed 's/psmdb-operator-//')

    local expected_from="${OPERATOR_FROM_VERSION:-}"

    if [[ -z "${expected_from}" ]]; then
        log_warn "OPERATOR_FROM_VERSION not set in MANIFEST — skipping version check"
        return
    fi

    if [[ "${installed_version}" == "${expected_from}" ]]; then
        log_ok "Version check passed: installed=${installed_version} matches bundle FROM=${expected_from}"
    elif [[ "${FORCE}" == "true" || "${DRY_RUN}" == "true" ]]; then
        log_warn "Version mismatch (installed: ${installed_version}, bundle FROM: ${expected_from})"
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warn "Proceeding anyway in dry-run mode — use --force to bypass on a real run"
        else
            log_warn "Proceeding anyway because --force was passed"
        fi
    else
        log_error "Version mismatch:"
        log_error "  Bundle expects installed version : ${expected_from}"
        log_error "  Currently installed              : ${installed_version}"
        echo "  → Prepare a ${installed_version}→${OPERATOR_TO_VERSION:-?} bundle first, or use --force to bypass"
        exit 1
    fi
}

# =============================================================================
# Dry-Run Summary (task 2.8)
# =============================================================================

dry_run_summary() {
    echo ""
    box "DRY-RUN: Upgrade Plan (no changes will be made)"
    echo ""

    printf "  %-20s %-25s %-25s\n" "Component" "Current Version" "Target Version"
    printf "  %-20s %-25s %-25s\n" "---------" "---------------" "--------------"

    [[ "${UPGRADE_OPERATOR:-false}" == "true" ]] && \
        printf "  %-20s %-25s %-25s\n" "Operator" "${OPERATOR_FROM_VERSION:-?}" "${OPERATOR_TO_VERSION:-?}"

    local pairs_count="${MONGODB_PAIRS_COUNT:-0}"
    for i in $(seq 1 "${pairs_count}"); do
        local from_var="MONGODB_PAIR_${i}_FROM"
        local to_var="MONGODB_PAIR_${i}_TO"
        printf "  %-20s %-25s %-25s\n" "MongoDB" "${!from_var:-?}" "${!to_var:-?}"
    done

    [[ "${UPGRADE_BACKUP_AGENT:-false}" == "true" ]] && \
        printf "  %-20s %-25s %-25s\n" "Backup Agent" "${BACKUP_AGENT_FROM_VERSION:-?}" "${BACKUP_AGENT_TO_VERSION:-?}"

    echo ""
    log_info "Images that would be imported: ${IMAGES_INCLUDED:-none}"
    log_info "CRDs would be updated        : ${UPGRADE_OPERATOR:-false}"
    echo ""

    log_ok "Dry-run complete — no changes made."
    log_info "Remove --dry-run to apply the upgrade."
    exit 0
}

# =============================================================================
# Rollback Snapshot Capture (task 2.9)
# =============================================================================

capture_rollback_snapshot() {
    log_step "Capturing Rollback Snapshot"

    SNAPSHOT_DIR="${LOG_DIR}/rollback/$(date +%Y-%m-%d-%H-%M)"
    mkdir -p "${SNAPSHOT_DIR}"

    # 1. Helm revision
    helm list --filter psmdb-operator -n "${MONGODB_NAMESPACE}" --no-headers 2>/dev/null \
        | awk '{print $3}' > "${SNAPSHOT_DIR}/helm-revision.txt"

    # 2. Helm values (--all captures defaults too)
    helm get values psmdb-operator --all -n "${MONGODB_NAMESPACE}" \
        > "${SNAPSHOT_DIR}/helm-values.yaml" 2>&1

    # 3. Old Helm chart — pull from repo at the currently-installed version
    local installed_chart_ver
    installed_chart_ver=$(helm list --filter psmdb-operator -n "${MONGODB_NAMESPACE}" \
        --no-headers 2>/dev/null | awk '{print $9}' | sed 's/psmdb-operator-//')
    if [[ -n "${installed_chart_ver}" ]]; then
        helm pull percona/psmdb-operator \
            --version "${installed_chart_ver}" \
            --destination "${SNAPSHOT_DIR}" \
            2>&1 | tee -a "${LOG_FILE}" || log_warn "Could not pull old chart from repo"
        local chart_tgz
        chart_tgz=$(find "${SNAPSHOT_DIR}" -maxdepth 1 -name "psmdb-operator-*.tgz" 2>/dev/null | head -1)
        if [[ -n "${chart_tgz}" ]]; then
            mv "${chart_tgz}" "${SNAPSHOT_DIR}/old-chart.tgz"
            log_ok "old-chart.tgz captured (v${installed_chart_ver})"
        else
            log_warn "old-chart.tgz not captured — Helm history fallback may not work"
        fi
    else
        log_warn "Could not determine installed chart version — skipping old-chart.tgz capture"
    fi

    # 4. CRD backup — explicit named resources (not grep)
    kubectl get crd \
        perconaservermongodbs.psmdb.percona.com \
        perconaservermongodbbackups.psmdb.percona.com \
        perconaservermongodbrestores.psmdb.percona.com \
        -o yaml > "${SNAPSHOT_DIR}/crd-backup.yaml" 2>&1 || \
        log_warn "Some Percona CRDs not found (may not all be installed)"

    # 5. PSMDB CR backup
    kubectl get psmdb -n "${MONGODB_NAMESPACE}" -o yaml \
        > "${SNAPSHOT_DIR}/psmdb-cr-backup.yaml" 2>&1

    # 6. Running images
    kubectl get pods -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
        > "${SNAPSHOT_DIR}/running-images.txt" 2>/dev/null || true

    # 7. Human-readable rollback instructions
    cat > "${SNAPSHOT_DIR}/ROLLBACK-INSTRUCTIONS.txt" << EOF
Percona MongoDB Operator — Rollback Instructions
================================================
Snapshot captured: $(date)
Namespace: ${MONGODB_NAMESPACE}

To rollback this upgrade, run:
  sudo ./rollback-mongodb-operator.sh --rollback-dir ${SNAPSHOT_DIR}

Manual rollback steps (if script unavailable):
  1. helm rollback psmdb-operator $(cat "${SNAPSHOT_DIR}/helm-revision.txt" 2>/dev/null || echo '<revision>') -n ${MONGODB_NAMESPACE} --wait
     OR (if Helm history is lost):
     helm upgrade --install psmdb-operator ${SNAPSHOT_DIR}/old-chart.tgz \
       --values ${SNAPSHOT_DIR}/helm-values.yaml -n ${MONGODB_NAMESPACE} --wait
  2. kubectl apply --server-side --force-conflicts -f ${SNAPSHOT_DIR}/crd-backup.yaml
  3. kubectl apply -f ${SNAPSHOT_DIR}/psmdb-cr-backup.yaml
EOF

    log_ok "Rollback snapshot captured:"
    log_ok "  ${SNAPSHOT_DIR}"
    echo ""
    box "Rollback snapshot: ${SNAPSHOT_DIR}"
    echo ""
}

# =============================================================================
# Log Before State (task 2.10)
# =============================================================================

log_before_state() {
    log_step "Current State (BEFORE UPGRADE)"

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
# Load Images (task 2.11)
# =============================================================================

load_images() {
    step_done "images-loaded" && {
        log_info "Container images already loaded, skipping."
        return
    }

    if [[ -z "${IMAGES_INCLUDED:-}" ]]; then
        log_info "No images in bundle — skipping image import."
        mark_done "images-loaded"
        return
    fi

    log_step "Loading Container Images into K3s"

    local tar_file="${WORK_DIR}/images/${IMAGES_FILE}"

    if [[ ! -f "${tar_file}" ]]; then
        log_error "Image archive not found: ${tar_file}"
        exit 1
    fi

    log_info "  Importing: ${IMAGES_FILE}"

    if k3s ctr images import "${tar_file}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Images imported successfully"
    else
        log_error "Failed to import image archive"
        exit 1
    fi

    local image_count
    # || echo 0 guards against grep non-zero when no percona images found
    image_count=$(k3s ctr --namespace k8s.io images list 2>/dev/null | grep -c "percona" || echo 0)
    log_ok "Verified: ${image_count} Percona image(s) in containerd"

    log_info "  Image architectures:"
    k3s ctr --namespace k8s.io images list 2>/dev/null \
        | grep "percona" \
        | awk '{printf "    %-80s %s\n", $1, $NF}' \
        | tee -a "${LOG_FILE}"

    mark_done "images-loaded"
}

# =============================================================================
# Upgrade CRDs (task 2.12)
# =============================================================================

upgrade_crds() {
    if [[ "${UPGRADE_OPERATOR:-false}" != "true" ]]; then
        log_info "Operator not being upgraded — skipping CRD update."
        return
    fi

    step_done "crds-applied" && {
        log_info "CRDs already applied, skipping."
        return
    }

    log_step "Applying Updated CRDs"

    local chart="${WORK_DIR}/helm-charts/${HELM_CHART}"

    if helm show crds "${chart}" 2>/dev/null | grep -q "kind: CustomResourceDefinition"; then
        helm show crds "${chart}" | kubectl apply --server-side -f - \
            2>&1 | tee -a "${LOG_FILE}"
        log_ok "CRDs applied"
    else
        log_info "No CRDs found in chart — skipping"
    fi

    mark_done "crds-applied"
}

# =============================================================================
# Upgrade Operator via Helm (task 2.13)
# =============================================================================

upgrade_operator() {
    if [[ "${UPGRADE_OPERATOR:-false}" != "true" ]]; then
        log_info "Operator not being upgraded — skipping Helm upgrade."
        return
    fi

    step_done "operator-done" && {
        log_info "Operator already upgraded, skipping."
        return
    }

    log_step "Upgrading Percona MongoDB Operator"

    local chart="${WORK_DIR}/helm-charts/${HELM_CHART}"

    log_info "  Upgrading from chart: ${chart}"

    if helm upgrade --install psmdb-operator "${chart}" \
        --namespace "${MONGODB_NAMESPACE}" \
        --set rbac.create=true \
        --set rbac.serviceAccountName=psmdb-operator \
        --wait \
        --timeout=5m \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Operator upgraded successfully"
    else
        log_error "Operator upgrade failed"
        echo "  → Check logs: kubectl logs deploy/psmdb-operator -n ${MONGODB_NAMESPACE}"
        echo "  → To rollback: sudo ./rollback-mongodb-operator.sh --rollback-dir ${SNAPSHOT_DIR}"
        exit 1
    fi

    mark_done "operator-done"
}

# =============================================================================
# Upgrade MongoDB CR (task 2.14)
# =============================================================================

upgrade_mongodb_cr() {
    local pairs_count="${MONGODB_PAIRS_COUNT:-0}"
    local needs_cr_patch=false
    [[ "${pairs_count}" -gt 0 ]]                  && needs_cr_patch=true
    [[ "${UPGRADE_BACKUP_AGENT:-false}" == "true" ]] && needs_cr_patch=true

    if [[ "${needs_cr_patch}" != "true" ]]; then
        log_info "No MongoDB CR patches needed — skipping."
        return
    fi

    step_done "mongodb-patched" && {
        log_info "MongoDB CR already patched, skipping."
        return
    }

    log_step "Patching PSMDB Custom Resources"

    # Wait for operator to be ready before touching the CR
    log_info "  Waiting for operator to be ready..."
    local timeout=300 elapsed=0 interval=5
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
        log_warn "Operator not ready after ${timeout}s — proceeding anyway"
    fi

    # Get all PSMDB CR names in the namespace
    local cr_names
    cr_names=$(kubectl get psmdb -n "${MONGODB_NAMESPACE}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    if [[ -z "${cr_names}" ]]; then
        log_info "  No PerconaServerMongoDB CRs found in namespace '${MONGODB_NAMESPACE}'"
        mark_done "mongodb-patched"
        return
    fi

    for cr_name in ${cr_names}; do
        log_info "  Patching CR: ${cr_name}"

        # Match this CR's current image against each pair; apply first match
        if [[ "${pairs_count}" -gt 0 ]]; then
            local current_image
            current_image=$(kubectl get psmdb "${cr_name}" -n "${MONGODB_NAMESPACE}" \
                -o jsonpath='{.spec.image}' 2>/dev/null || echo "")

            local matched=false
            for i in $(seq 1 "${pairs_count}"); do
                local from_var="MONGODB_PAIR_${i}_FROM"
                local to_var="MONGODB_PAIR_${i}_TO"
                local from_version="${!from_var}"
                local to_version="${!to_var}"

                if [[ "${current_image}" == *"${from_version}"* ]]; then
                    local new_mongo_image="percona/percona-server-mongodb:${to_version}"
                    kubectl patch psmdb "${cr_name}" -n "${MONGODB_NAMESPACE}" \
                        --type=merge \
                        -p "{\"spec\":{\"image\":\"${new_mongo_image}\"}}" \
                        2>&1 | tee -a "${LOG_FILE}"
                    log_ok "  spec.image → ${new_mongo_image}"
                    MONGODB_PAIRS_PATCHED="${MONGODB_PAIRS_PATCHED} ${i}"
                    matched=true
                    break
                fi
            done

            if [[ "${matched}" != "true" ]]; then
                log_info "  spec.image: no matching upgrade pair for current image (${current_image})"
            fi
        fi

        # Patch backup agent image
        if [[ "${UPGRADE_BACKUP_AGENT:-false}" == "true" && -n "${BACKUP_AGENT_TO_VERSION:-}" ]]; then
            local new_backup_image="percona/percona-backup-mongodb:${BACKUP_AGENT_TO_VERSION}"
            kubectl patch psmdb "${cr_name}" -n "${MONGODB_NAMESPACE}" \
                --type=merge \
                -p "{\"spec\":{\"backup\":{\"image\":\"${new_backup_image}\"}}}" \
                2>&1 | tee -a "${LOG_FILE}"
            log_ok "  spec.backup.image → ${new_backup_image}"
        fi
    done

    mark_done "mongodb-patched"
}

# =============================================================================
# Verify Upgrade (task 2.15)
# =============================================================================

verify_upgrade() {
    log_step "Verifying Upgrade"

    log_info "  Waiting for operator to be ready..."

    local timeout=1800 elapsed=0 interval=10

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
        log_warn "Operator not ready after ${timeout}s — upgrade applied but health uncertain"
        log_warn "Diagnostic commands:"
        log_warn "  kubectl get psmdb -n ${MONGODB_NAMESPACE}"
        log_warn "  kubectl get pods -n ${MONGODB_NAMESPACE}"
        log_warn "  kubectl logs deploy/psmdb-operator -n ${MONGODB_NAMESPACE} --tail=50"
        return 0
    fi

    # If MongoDB was upgraded, also wait for PSMDB .status.state = ready
    local needs_psmdb_check=false
    [[ -n "${MONGODB_PAIRS_PATCHED// /}" ]]          && needs_psmdb_check=true
    [[ "${UPGRADE_BACKUP_AGENT:-false}" == "true" ]] && needs_psmdb_check=true

    if [[ "${needs_psmdb_check}" == "true" ]]; then
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
    fi

    return 0
}

# =============================================================================
# Log After State (task 2.16)
# =============================================================================

log_after_state() {
    log_step "Current State (AFTER UPGRADE)"

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
    log_info "  Rollback snapshot location:"
    log_info "    ${SNAPSHOT_DIR}"
    echo "" | tee -a "${LOG_FILE}"
}

# =============================================================================
# Output Info (task 2.17)
# =============================================================================

output_info() {
    log_step "Upgrade Complete"

    echo ""
    box "Percona MongoDB Operator Upgraded!"
    echo ""

    log_ok "Namespace: ${MONGODB_NAMESPACE}"
    [[ "${UPGRADE_OPERATOR:-false}" == "true" ]] && \
        log_ok "Operator: ${OPERATOR_FROM_VERSION} → ${OPERATOR_TO_VERSION}"

    for i in ${MONGODB_PAIRS_PATCHED}; do
        local from_var="MONGODB_PAIR_${i}_FROM"
        local to_var="MONGODB_PAIR_${i}_TO"
        log_ok "MongoDB: ${!from_var} → ${!to_var}"
    done

    [[ "${UPGRADE_BACKUP_AGENT:-false}" == "true" ]] && \
        log_ok "Backup Agent: ${BACKUP_AGENT_FROM_VERSION} → ${BACKUP_AGENT_TO_VERSION}"

    echo ""
    box "Rollback snapshot: ${SNAPSHOT_DIR}"
    echo ""

    echo "  Verify status:"
    echo "    kubectl get psmdb -n ${MONGODB_NAMESPACE}"
    echo "    kubectl get pods -n ${MONGODB_NAMESPACE}"
    echo ""
    echo "  If rollback needed:"
    echo "    sudo ./rollback-mongodb-operator.sh --rollback-dir ${SNAPSHOT_DIR}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    init
    extract_bundle
    verify_bundle
    check_prerequisites
    validate_from_version

    # Dry-run exits here (after validation, before any changes)
    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_run_summary
    fi

    capture_rollback_snapshot
    log_before_state
    load_images
    upgrade_crds
    upgrade_operator
    upgrade_mongodb_cr
    verify_upgrade
    log_after_state
    output_info

    log_info "Upgrade finished successfully."
    log_info "Logs: ${LOG_FILE}"

    echo ""
    box "Ready!"
    echo ""
}

main "$@"
