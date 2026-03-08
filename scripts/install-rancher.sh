#!/bin/bash

################################################################################
# Rancher Server — Automated Offline Installation
#
# Purpose: Deploy Rancher management server on a standalone K3s cluster
#          for managing multiple downstream K3s clusters
#
# Usage:   sudo ./install-rancher.sh \
#            --bundle-path /opt/offline-bundle \
#            --rancher-ip 192.168.64.11 \
#            --rancher-hostname rancher \
#            --bootstrap-password changeme
#
# Requirements:
#   - Offline bundle prepared with prepare-offline-bundle.sh
#   - K3s binaries, Helm charts, images already available
#   - 4 GB+ RAM, 2 CPU, 30 GB disk recommended
#   - Ubuntu 22.04+ or similar
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

BUNDLE_PATH="${BUNDLE_PATH:-/opt/offline-bundle}"
RANCHER_IP="${RANCHER_IP:-192.168.64.11}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher}"
RANCHER_DOMAIN="${RANCHER_HOSTNAME}.${RANCHER_IP}.sslip.io"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-changeme}"
RANCHER_VERSION="2.13.2"
CERT_MANAGER_VERSION="v1.19.4"
TRAEFIK_VERSION="39.0.0"

LOG_DIR="/var/log/rancher-install"
STEP_DIR="${LOG_DIR}/.steps"
LOG_FILE="${LOG_DIR}/rancher-install.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# =============================================================================
# Utility Functions
# =============================================================================

step_done() {
    [[ -f "${STEP_DIR}/$1" ]]
}

mark_done() {
    mkdir -p "${STEP_DIR}"
    touch "${STEP_DIR}/$1"
}

box() {
    local text="$1"
    local width=$((${#text} + 4))
    printf "  ┌%s┐\n" "$(printf '─%.0s' $(seq 1 $((width - 2))))"
    printf "  │ %s │\n" "$text"
    printf "  └%s┘\n" "$(printf '─%.0s' $(seq 1 $((width - 2))))"
}

# =============================================================================
# 1. Initialization & Validation
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${STEP_DIR}"

    box "Rancher Server — Automated Offline Installation"

    log_info "Configuration:"
    log_info "  Bundle Path      : ${BUNDLE_PATH}"
    log_info "  Rancher IP       : ${RANCHER_IP}"
    log_info "  Rancher Domain   : ${RANCHER_DOMAIN}"
    log_info "  Rancher Version  : ${RANCHER_VERSION}"
}

verify_bundle() {
    step_done "bundle-verified" && {
        log_info "Offline bundle already verified, skipping."
        return
    }

    log_step "Verifying Offline Bundle at ${BUNDLE_PATH}"

    local required_files=(
        "binaries/k3s"
        "binaries/install.sh"
        "images/k3s-airgap-images-arm64.tar.gz"
        "binaries/kubectl"
        "binaries/helm"
        "binaries/crictl"
        "helm-charts/cert-manager-${CERT_MANAGER_VERSION}.tgz"
        "helm-charts/rancher-${RANCHER_VERSION}.tgz"
        "helm-charts/traefik-${TRAEFIK_VERSION}.tgz"
        "images/rancher-images.tar"
    )

    for file in "${required_files[@]}"; do
        if [[ -f "${BUNDLE_PATH}/${file}" ]]; then
            log_ok "${file}"
        else
            log_error "Missing: ${file}"
            exit 1
        fi
    done

    log_ok "Bundle verified"
    mark_done "bundle-verified"
}

check_prerequisites() {
    step_done "prerequisites-checked" && {
        log_info "Prerequisites already checked, skipping."
        return
    }

    log_step "Checking System Prerequisites"

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_ok "Running as root"

    # Check swap is disabled
    if [[ $(swapon --show | wc -l) -gt 1 ]]; then
        log_warn "Swap is enabled. Disabling..."
        swapoff -a
        sed -i '/swap/d' /etc/fstab || true
        log_ok "Swap disabled"
    fi
    log_ok "Swap is disabled"

    # Check if K3s is already running
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_warn "K3s is already running. Removing for clean installation..."
        /usr/local/bin/k3s-killall.sh 2>/dev/null || true
        systemctl stop k3s || true
        sleep 2
    fi

    mark_done "prerequisites-checked"
}

# =============================================================================
# 2. Prepare K3s Files
# =============================================================================

prepare_k3s_files() {
    step_done "k3s-files-prepared" && {
        log_info "K3s files already prepared, skipping."
        return
    }

    log_step "Preparing K3s Files from Bundle"

    cp "${BUNDLE_PATH}/binaries/k3s" /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s
    log_ok "k3s binary → /usr/local/bin/k3s"

    # Copy airgap images
    mkdir -p /var/lib/rancher/k3s/agent/images/
    cp "${BUNDLE_PATH}/images/k3s-airgap-images-arm64.tar.gz" /var/lib/rancher/k3s/agent/images/
    log_ok "Airgap images → /var/lib/rancher/k3s/agent/images/"

    # Copy binaries
    cp "${BUNDLE_PATH}/binaries/kubectl" /usr/local/bin/
    cp "${BUNDLE_PATH}/binaries/helm" /usr/local/bin/
    cp "${BUNDLE_PATH}/binaries/crictl" /usr/local/bin/
    chmod +x /usr/local/bin/{kubectl,helm,crictl}
    log_ok "kubectl, helm, crictl → /usr/local/bin/"

    mark_done "k3s-files-prepared"
}

# =============================================================================
# 3. Install K3s Server
# =============================================================================

install_k3s_server() {
    step_done "k3s-server-install" && {
        log_info "K3s server already installed, skipping."
        return
    }

    log_step "Installing K3s Server (Rancher local cluster)"

    log_info "  Disabling traefik (will use manual traefik)"
    log_info "  Enabling servicelb for LoadBalancer support"
    log_info "  Setting kubeconfig mode to 644 for access"

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_BIN_DIR=/usr/local/bin \
    INSTALL_K3S_EXEC="server \
        --disable traefik \
        --write-kubeconfig-mode=644" \
        bash "${BUNDLE_PATH}/binaries/install.sh" 2>&1 | tee -a "${LOG_FILE}"

    mark_done "k3s-server-install"
    log_ok "K3s server installation complete"
}

# =============================================================================
# 4. Wait for K3s API
# =============================================================================

wait_for_k3s() {
    log_step "Waiting for K3s API Server"

    log_info "  Giving K3s 15s to initialise..."
    sleep 15

    local timeout=300
    local elapsed=15
    local interval=5
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if kubectl get nodes &>/dev/null; then
            log_ok "K3s API server is responsive (${elapsed}s)"
            return 0
        fi
        log_info "  Waiting for API server... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_error "K3s API server did not become responsive within ${timeout}s"
    exit 1
}

# =============================================================================
# 5. Configure kubectl
# =============================================================================

configure_kubectl() {
    step_done "kubectl-config" && {
        log_info "kubectl already configured, skipping."
        return
    }

    log_step "Configuring kubectl Access"

    local kc="/etc/rancher/k3s/k3s.yaml"
    export KUBECONFIG="${kc}"

    # Configure for root user
    mkdir -p /root/.kube
    cp "${kc}" /root/.kube/config
    chmod 600 /root/.kube/config
    log_ok "kubectl configured for root user"

    # Add to shell profiles for future sessions
    local profile_cmd="export KUBECONFIG=${kc}"

    if ! grep -q "KUBECONFIG" /etc/environment; then
        echo "KUBECONFIG=${kc}" >> /etc/environment
    fi

    # Add local DNS entry for airgap environments (sslip.io needs internet DNS)
    if ! grep -q "${RANCHER_DOMAIN}" /etc/hosts; then
        echo "${RANCHER_IP} ${RANCHER_DOMAIN}" >> /etc/hosts
        log_ok "Added ${RANCHER_DOMAIN} → /etc/hosts for local DNS resolution"
    fi

    mark_done "kubectl-config"
}

# =============================================================================
# 6. Load Rancher Images
# =============================================================================

load_rancher_images() {
    step_done "rancher-images-loaded" && {
        log_info "Rancher images already loaded, skipping."
        return
    }

    log_step "Loading Rancher Container Images"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    log_info "  This may take 2-5 minutes depending on image size..."

    # Import rancher images
    k3s ctr images import "${BUNDLE_PATH}/images/rancher-images.tar" 2>&1 | tee -a "${LOG_FILE}"

    # Verify images are loaded
    local image_count=$(k3s ctr --namespace k8s.io images list | grep -c "rancher\|cert-manager\|traefik" || echo 0)
    log_ok "Loaded ${image_count} images"

    mark_done "rancher-images-loaded"
}

# =============================================================================
# 7. Install cert-manager
# =============================================================================

install_cert_manager() {
    step_done "cert-manager-install" && {
        log_info "cert-manager already installed, skipping."
        return
    }

    log_step "Installing cert-manager"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

    helm install cert-manager "${BUNDLE_PATH}/helm-charts/cert-manager-${CERT_MANAGER_VERSION}.tgz" \
        --namespace cert-manager \
        --set installCRDs=true \
        2>&1 | tee -a "${LOG_FILE}"

    # Wait for cert-manager to be ready
    log_info "  Waiting for cert-manager pods to be ready..."
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=2m || true

    mark_done "cert-manager-install"
    log_ok "cert-manager installed"
}

# =============================================================================
# 8. Install Traefik
# =============================================================================

install_traefik() {
    step_done "traefik-install" && {
        log_info "traefik already installed, skipping."
        return
    }

    log_step "Installing Traefik Ingress Controller"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    helm install traefik "${BUNDLE_PATH}/helm-charts/traefik-${TRAEFIK_VERSION}.tgz" \
        --namespace kube-system \
        --set service.type=LoadBalancer \
        --set ingressClass.enabled=true \
        --set ingressClass.name=traefik \
        --set providers.kubernetesIngress.publishedService.enabled=true \
        2>&1 | tee -a "${LOG_FILE}"

    # Wait for traefik to be ready
    log_info "  Waiting for traefik deployment to be ready..."
    kubectl rollout status deployment/traefik -n kube-system --timeout=2m || true

    mark_done "traefik-install"
    log_ok "traefik installed"
}

# =============================================================================
# 9. Generate Self-Signed Certificates
# =============================================================================

generate_certificates() {
    step_done "certificates-generated" && {
        log_info "Certificates already generated, skipping."
        return
    }

    log_step "Generating Self-Signed Certificates for Rancher"

    local cert_dir="/opt/rancher-certs"
    mkdir -p "${cert_dir}"
    cd "${cert_dir}"

    log_info "  Generating Root CA..."
    openssl genrsa -out rancher-root-ca.key 4096 &>/dev/null
    openssl req -x509 -new -nodes \
        -key rancher-root-ca.key \
        -sha256 -days 3650 \
        -out rancher-root-ca.crt \
        -subj "/C=US/O=RancherOrg/CN=Rancher-Private-CA" &>/dev/null
    log_ok "Root CA generated"

    log_info "  Generating server certificate..."
    openssl genrsa -out privkey.pem 4096 &>/dev/null

    # Create OpenSSL config
    cat > rancher-openssl.cnf <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = US
O  = RancherOrg
CN = ${RANCHER_DOMAIN}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${RANCHER_DOMAIN}
IP.1  = ${RANCHER_IP}
EOF

    openssl req -new \
        -key privkey.pem \
        -out rancher.csr \
        -config rancher-openssl.cnf &>/dev/null

    openssl x509 -req \
        -in rancher.csr \
        -CA rancher-root-ca.crt \
        -CAkey rancher-root-ca.key \
        -CAcreateserial \
        -out server.crt \
        -days 825 \
        -sha256 \
        -extensions req_ext \
        -extfile rancher-openssl.cnf &>/dev/null

    # Create full chain
    cat server.crt rancher-root-ca.crt > fullchain.pem

    log_ok "Server certificate generated"
    log_ok "Certificates saved to ${cert_dir}/"

    # Trust the CA in system
    cp rancher-root-ca.crt /usr/local/share/ca-certificates/rancher-root-ca.crt
    update-ca-certificates &>/dev/null
    log_ok "CA certificate installed in system trust store"

    mark_done "certificates-generated"
}

# =============================================================================
# 10. Create TLS Secret in Kubernetes
# =============================================================================

create_tls_secret() {
    step_done "tls-secret-created" && {
        log_info "TLS secret already created, skipping."
        return
    }

    log_step "Creating Kubernetes TLS Secret"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local cert_dir="/opt/rancher-certs"

    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n cattle-system delete secret rancher-tls --ignore-not-found=true
    kubectl -n cattle-system create secret tls rancher-tls \
        --cert="${cert_dir}/fullchain.pem" \
        --key="${cert_dir}/privkey.pem"

    log_ok "TLS secret created in cattle-system namespace"

    # Create tls-ca secret for Rancher CA certificate
    kubectl -n cattle-system delete secret tls-ca --ignore-not-found=true
    kubectl -n cattle-system create secret generic tls-ca \
        --from-file=cacerts.pem="${cert_dir}/rancher-root-ca.crt"

    log_ok "TLS CA secret created in cattle-system namespace"

    mark_done "tls-secret-created"
}

# =============================================================================
# 11. Install Rancher
# =============================================================================

install_rancher() {
    step_done "rancher-install" && {
        log_info "Rancher already installed, skipping."
        return
    }

    log_step "Installing Rancher Management Server"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    log_info "  Hostname: ${RANCHER_DOMAIN}"
    log_info "  Bootstrap Password: ${BOOTSTRAP_PASSWORD}"

    helm upgrade --install rancher "${BUNDLE_PATH}/helm-charts/rancher-${RANCHER_VERSION}.tgz" \
        --namespace cattle-system \
        --set hostname="${RANCHER_DOMAIN}" \
        --set ingress.enabled=true \
        --set ingress.ingressClassName=traefik \
        --set ingress.tls.source=secret \
        --set ingress.tls.secretName=rancher-tls \
        --set bootstrapPassword="${BOOTSTRAP_PASSWORD}" \
        --set privateCA=true \
        2>&1 | tee -a "${LOG_FILE}"

    mark_done "rancher-install"
    log_ok "Rancher installation complete"
}

# =============================================================================
# 12. Wait for Rancher to be Ready
# =============================================================================

wait_for_rancher() {
    log_step "Waiting for Rancher to be Ready"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    log_info "  Waiting for rancher deployment to be ready..."
    if kubectl rollout status deployment/rancher -n cattle-system --timeout=5m 2>/dev/null; then
        log_ok "Rancher is ready"
    else
        log_warn "Rancher deployment status unclear, but proceeding..."
    fi

    # Wait a bit more for the service to be fully initialized
    sleep 10
}

# =============================================================================
# 13. Output Connection Details
# =============================================================================

output_access_info() {
    log_step "Rancher Access Information"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo ""
    box "Rancher Server Ready!"
    echo ""

    log_ok "Rancher URL: https://${RANCHER_DOMAIN}:31550"
    log_ok "Bootstrap Password: ${BOOTSTRAP_PASSWORD}"
    log_ok "IP Address: ${RANCHER_IP}"

    echo ""
    log_info "Access Methods:"
    log_info "  Browser: https://${RANCHER_DOMAIN}:31550"
    log_info "  Direct IP: https://${RANCHER_IP}:31550 (with -H 'Host: ${RANCHER_DOMAIN}')"

    echo ""
    log_info "Next steps:"
    log_info "  1. Open https://${RANCHER_DOMAIN}:31550 in browser (accept self-signed cert)"
    log_info "  2. Login with password: ${BOOTSTRAP_PASSWORD}"
    log_info "  3. Set a new admin password"
    log_info "  4. Import your HA K3s cluster via UI"

    echo ""
    log_info "To update /etc/hosts locally (if sslip.io doesn't work):"
    log_info "  echo '${RANCHER_IP} ${RANCHER_DOMAIN}' | sudo tee -a /etc/hosts"

    echo ""
    log_info "Rancher kubeconfig:"
    log_info "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    log_info "  kubectl get pods -n cattle-system"

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
            --rancher-ip)
                RANCHER_IP="$2"
                shift 2
                ;;
            --rancher-hostname)
                RANCHER_HOSTNAME="$2"
                shift 2
                ;;
            --bootstrap-password)
                BOOTSTRAP_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: sudo ./install-rancher.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --bundle-path PATH              Path to offline bundle (default: /opt/offline-bundle)"
                echo "  --rancher-ip IP                 IP address of Rancher VM (default: 192.168.64.11)"
                echo "  --rancher-hostname NAME         Hostname for Rancher domain (default: rancher)"
                echo "  --bootstrap-password PASSWORD   Initial admin password (default: changeme)"
                echo "  -h, --help                      Show this help message"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Recalculate RANCHER_DOMAIN after parsing arguments
    RANCHER_DOMAIN="${RANCHER_HOSTNAME}.${RANCHER_IP}.sslip.io"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    parse_args "$@"
    init
    verify_bundle
    check_prerequisites
    prepare_k3s_files
    install_k3s_server
    wait_for_k3s
    configure_kubectl
    load_rancher_images
    install_cert_manager
    install_traefik
    generate_certificates
    create_tls_secret
    install_rancher
    wait_for_rancher
    output_access_info

    echo ""
    box "Installation Complete!"
    echo ""
}

main "$@"
