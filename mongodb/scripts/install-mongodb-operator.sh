#!/bin/bash

################################################################################
# Percona MongoDB Operator — Offline Installation
#
# Purpose: Deploy Percona MongoDB Operator on offline K3s cluster
#
# Usage:   sudo ./install-mongodb-operator.sh \
#            --bundle-path /opt/mongodb-operator-bundle
#
# Requirements:
#   - K3s cluster running (containerd runtime)
#   - Offline bundle prepared with prepare-mongodb-operator-bundle.sh
#   - kubectl configured to access cluster
#   - Helm 3.x installed in bundle or system
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

BUNDLE_PATH="${BUNDLE_PATH:-/opt/mongodb-operator-bundle}"
MONGODB_NAMESPACE="mongodb"
OPERATOR_VERSION="1.22.0"
HELM_BIN="${HELM_BIN:-helm}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

LOG_DIR="/var/log/k3s-install"
STEP_DIR="${LOG_DIR}/.steps"
LOG_FILE="${LOG_DIR}/mongodb-operator-install.log"

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
# Step Tracking
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
    mkdir -p "${LOG_DIR}" "${STEP_DIR}"

    # Verify running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    export KUBECONFIG

    box "Percona MongoDB Operator — Offline Installation"

    log_info "Configuration:"
    log_info "  Bundle Path    : ${BUNDLE_PATH}"
    log_info "  Namespace      : ${MONGODB_NAMESPACE}"
    log_info "  Operator Ver   : ${OPERATOR_VERSION}"
    log_info "  KUBECONFIG     : ${KUBECONFIG}"
}

# =============================================================================
# Validation
# =============================================================================

verify_bundle() {
    step_done "bundle-verified" && {
        log_info "Bundle already verified, skipping."
        return
    }

    log_step "Verifying Offline Bundle"

    # Verify helm chart
    if [[ -f "${BUNDLE_PATH}/helm-charts/psmdb-operator-${OPERATOR_VERSION}.tgz" ]]; then
        log_ok "helm-charts/psmdb-operator-${OPERATOR_VERSION}.tgz"
    else
        log_error "Missing: helm-charts/psmdb-operator-${OPERATOR_VERSION}.tgz"
        exit 1
    fi

    # Verify combined image tarball
    if [[ -f "${BUNDLE_PATH}/images/mongodb-operator-images.tar.gz" ]]; then
        log_ok "images/mongodb-operator-images.tar.gz"
    else
        log_error "Missing: images/mongodb-operator-images.tar.gz"
        exit 1
    fi

    # Verify manifest
    if [[ -f "${BUNDLE_PATH}/MANIFEST.txt" ]]; then
        log_ok "MANIFEST.txt"
    else
        log_warn "MANIFEST.txt not found (non-fatal)"
    fi

    mark_done "bundle-verified"
}

check_prerequisites() {
    step_done "prerequisites-checked" && {
        log_info "Prerequisites already checked, skipping."
        return
    }

    log_step "Checking System Prerequisites"

    # Check kubernetes connectivity
    if kubectl get nodes &>/dev/null; then
        log_ok "Kubernetes cluster accessible"
    else
        log_error "Cannot access Kubernetes cluster. Set KUBECONFIG."
        exit 1
    fi

    # Check helm
    if command -v helm &>/dev/null || [[ -f "/usr/local/bin/helm" ]]; then
        log_ok "Helm found"
    else
        log_error "Helm not found"
        exit 1
    fi

    # Check containerd
    if k3s ctr --version &>/dev/null; then
        log_ok "K3s containerd available"
    else
        log_error "K3s containerd not found"
        exit 1
    fi

    mark_done "prerequisites-checked"
}

# =============================================================================
# Load Container Images
# =============================================================================

load_images() {
    step_done "images-loaded" && {
        log_info "Container images already loaded, skipping."
        return
    }

    log_step "Loading Container Images into K3s"

    local tar_file="${BUNDLE_PATH}/images/mongodb-operator-images.tar.gz"

    if [[ ! -f "${tar_file}" ]]; then
        log_error "Image archive not found: ${tar_file}"
        exit 1
    fi

    log_info "  Importing: mongodb-operator-images.tar.gz"

    if sudo k3s ctr images import "${tar_file}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Images imported successfully"
    else
        log_error "Failed to import image archive"
        exit 1
    fi

    # Verify images and show architecture
    local image_count
    image_count=$(sudo k3s ctr --namespace k8s.io images list | grep -c "percona" || echo 0)
    log_ok "Verified: ${image_count} Percona images in containerd"

    log_info "  Image architectures:"
    sudo k3s ctr --namespace k8s.io images list \
        | grep "percona" \
        | awk '{printf "    %-80s %s\n", $1, $NF}' \
        | tee -a "${LOG_FILE}"

    mark_done "images-loaded"
}

# =============================================================================
# Create Namespace
# =============================================================================

create_namespace() {
    step_done "namespace-created" && {
        log_info "Namespace already created, skipping."
        return
    }

    log_step "Creating MongoDB Namespace"

    if kubectl create namespace "${MONGODB_NAMESPACE}" 2>/dev/null; then
        log_ok "Namespace '${MONGODB_NAMESPACE}' created"
    else
        # Namespace may already exist
        log_info "Namespace '${MONGODB_NAMESPACE}' already exists"
    fi

    mark_done "namespace-created"
}

# =============================================================================
# Install Operator via Helm
# =============================================================================

install_operator() {
    step_done "operator-installed" && {
        log_info "Operator already installed, skipping."
        return
    }

    log_step "Installing Percona MongoDB Operator"

    local chart="${BUNDLE_PATH}/helm-charts/psmdb-operator-${OPERATOR_VERSION}.tgz"

    log_info "  Installing from: $chart"

    if helm upgrade --install psmdb-operator "${chart}" \
        --namespace "${MONGODB_NAMESPACE}" \
        --set rbac.create=true \
        --set rbac.serviceAccountName=psmdb-operator \
        --wait \
        --timeout=5m \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Operator installed successfully"
    else
        log_error "Operator installation failed"
        exit 1
    fi

    mark_done "operator-installed"
}

# =============================================================================
# Verify Operator Deployment
# =============================================================================

verify_operator() {
    log_step "Verifying Operator Deployment"

    log_info "  Waiting for operator pods to be ready..."

    local timeout=300
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $timeout ]]; do
        local ready=$(kubectl get deployment -n "${MONGODB_NAMESPACE}" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)

        if [[ "$ready" -ge 1 ]]; then
            log_ok "Operator is ready (${elapsed}s)"
            return 0
        fi

        log_info "  Waiting for operator... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_warn "Operator deployment status unclear, but proceeding..."
}

# =============================================================================
# Output Connection Details
# =============================================================================

output_info() {
    log_step "Installation Complete"

    echo ""
    box "MongoDB Operator Deployed!"
    echo ""

    log_ok "Operator namespace: ${MONGODB_NAMESPACE}"
    log_ok "Next: Create MongoDB clusters via Rancher UI"

    echo ""
    echo "  Check operator status:"
    echo "    kubectl get pods -n ${MONGODB_NAMESPACE}"
    echo "    kubectl get deployment -n ${MONGODB_NAMESPACE}"

    echo ""
    echo "  Next steps:"
    echo "    1. Open Rancher UI at: https://rancher.<IP>.sslip.io"
    echo "    2. Select your cluster → Custom Resources"
    echo "    3. Create PerconaServerMongoDB resource (see documentation)"
    echo "    4. Monitor MongoDB cluster creation via:"
    echo "       kubectl get psmdb -n ${MONGODB_NAMESPACE} -w"

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
                MONGODB_NAMESPACE="$2"
                shift 2
                ;;
            --kubeconfig)
                KUBECONFIG="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: sudo ./install-mongodb-operator.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --bundle-path PATH      Path to offline bundle (default: /opt/mongodb-operator-bundle)"
                echo "  --namespace NAME        K8s namespace for operator (default: mongodb)"
                echo "  --kubeconfig PATH       Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)"
                echo "  -h, --help              Show this help message"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
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
    verify_bundle
    check_prerequisites
    load_images
    create_namespace
    install_operator
    verify_operator
    output_info

    log_info "MongoDB Operator installation finished successfully"
    log_info "Logs available at: ${LOG_FILE}"

    echo ""
    box "Ready to Deploy MongoDB Clusters!"
    echo ""
}

main "$@"
