#!/bin/bash

################################################################################
# rollback-rancher.sh
#
# Cleanly remove the Rancher management server and its supporting components
# from the standalone Rancher VM, returning it to pre-install state.
#
# Usage:
#   sudo ./rollback-rancher.sh [OPTIONS]
#
# Options:
#   --rancher     Remove Rancher Helm release only
#   --traefik     Remove Traefik Helm release only
#   --cert-manager Remove cert-manager Helm release only
#   --k3s         Remove K3s server and all data
#   --certs       Remove generated certificates from /opt/rancher-certs
#   --all         Remove everything above + wipe logs (full clean slate)
#   --force       Skip confirmation prompt
#   -h, --help    Show this help
#
# Examples:
#   # Remove only Rancher (keep K3s + Traefik + cert-manager):
#   sudo ./rollback-rancher.sh --rancher
#
#   # Full clean slate — remove everything:
#   sudo ./rollback-rancher.sh --all --force
#
#   # Retry Rancher install after failure:
#   sudo ./rollback-rancher.sh --rancher --certs --force
#   sudo ./install-rancher.sh ...
#
################################################################################

set -euo pipefail

# =============================================================================
# Color Codes
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Flags
# =============================================================================
REMOVE_RANCHER=false
REMOVE_TRAEFIK=false
REMOVE_CERT_MANAGER=false
REMOVE_K3S=false
REMOVE_CERTS=false
REMOVE_ALL=false
FORCE=false

LOG_DIR="/var/log/rancher-install"
LOG_FILE="${LOG_DIR}/rollback.log"
STEP_DIR="${LOG_DIR}/.steps"

# =============================================================================
# Logging
# =============================================================================
log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date +'%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}  ✔ $*${NC}" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${GREEN}  ✔ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}  ⚠ $*${NC}" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${YELLOW}  ⚠ $*${NC}"; }
log_error() { echo -e "${RED}  ✘ ERROR: $*${NC}" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${RED}  ✘ ERROR: $*${NC}"; }
log_step()  { echo -e "${BLUE}══ [STEP] $(date +'%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${BLUE}══ [STEP] $*${NC}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF

${BLUE}rollback-rancher.sh${NC} — Remove Rancher and supporting components

${BLUE}USAGE${NC}
  sudo $0 [OPTIONS]

${BLUE}SCOPE FLAGS (combine as needed)${NC}
  --rancher        Remove Rancher Helm release (cattle-system namespace)
  --traefik        Remove Traefik Helm release
  --cert-manager   Remove cert-manager Helm release + namespace
  --k3s            Remove K3s server, binaries, and all data
  --certs          Remove generated certificates (/opt/rancher-certs/)
  --all            Expand to all of the above + wipe logs

${BLUE}CONTROL FLAGS${NC}
  --force          Skip confirmation prompt
  -h, --help       Show this help and exit

${BLUE}EXAMPLES${NC}
  # Remove only Rancher (retry install without rebuilding K3s)
  sudo $0 --rancher --certs --force

  # Remove Rancher + Traefik (keep cert-manager + K3s)
  sudo $0 --rancher --traefik --force

  # Complete clean slate — restore VM to pre-install state
  sudo $0 --all --force

${BLUE}RECOMMENDED PATTERNS BY SCENARIO${NC}

  Re-install Rancher only (keep K3s running):
    sudo $0 --rancher --certs --force
    sudo ./install-rancher.sh ...

  Re-install everything from scratch:
    sudo $0 --all --force
    sudo ./install-rancher.sh ...

EOF
}

# =============================================================================
# Parse Arguments
# =============================================================================
parse_args() {
    if [[ $# -eq 0 ]]; then
        log_error "No flags specified. Use --all for full cleanup or -h for help."
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rancher)        REMOVE_RANCHER=true; shift ;;
            --traefik)        REMOVE_TRAEFIK=true; shift ;;
            --cert-manager)   REMOVE_CERT_MANAGER=true; shift ;;
            --k3s)            REMOVE_K3S=true; shift ;;
            --certs)          REMOVE_CERTS=true; shift ;;
            --all)            REMOVE_ALL=true; shift ;;
            --force)          FORCE=true; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)
                log_error "Unknown flag: $1"
                usage
                exit 1
                ;;
        esac
    done

    # --all expands to everything
    if [[ "${REMOVE_ALL}" == "true" ]]; then
        REMOVE_RANCHER=true
        REMOVE_TRAEFIK=true
        REMOVE_CERT_MANAGER=true
        REMOVE_K3S=true
        REMOVE_CERTS=true
    fi
}

# =============================================================================
# Confirm
# =============================================================================
confirm() {
    if [[ "${FORCE}" == "true" ]]; then
        return
    fi

    echo ""
    echo -e "${YELLOW}  The following will be removed:${NC}"
    [[ "${REMOVE_RANCHER}"       == "true" ]] && echo "    • Rancher Helm release + cattle-system namespace"
    [[ "${REMOVE_TRAEFIK}"       == "true" ]] && echo "    • Traefik Helm release"
    [[ "${REMOVE_CERT_MANAGER}"  == "true" ]] && echo "    • cert-manager Helm release + namespace"
    [[ "${REMOVE_K3S}"           == "true" ]] && echo "    • K3s server, binaries, and all cluster data"
    [[ "${REMOVE_CERTS}"         == "true" ]] && echo "    • TLS certificates in /opt/rancher-certs/"
    [[ "${REMOVE_ALL}"           == "true" ]] && echo "    • Installation logs in /var/log/rancher-install/"
    echo ""
    read -rp "  Are you sure? (yes/no): " confirm_input
    if [[ "${confirm_input}" != "yes" ]]; then
        echo "  Aborted."
        exit 0
    fi
}

# =============================================================================
# Remove Rancher Helm Release
# =============================================================================
remove_rancher() {
    log_step "Removing Rancher Helm Release"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if helm -n cattle-system list 2>/dev/null | grep -q "rancher"; then
        helm uninstall rancher -n cattle-system --timeout 120s 2>&1 || \
            log_warn "helm uninstall rancher failed — may already be removed"
        log_ok "Rancher Helm release uninstalled"
    else
        log_warn "Rancher Helm release not found — skipping"
    fi

    # Delete the TLS secret
    kubectl -n cattle-system delete secret rancher-tls --ignore-not-found=true 2>/dev/null || true
    kubectl -n cattle-system delete secret tls-ca --ignore-not-found=true 2>/dev/null || true
    log_ok "Rancher TLS secrets removed"

    # Remove cattle-system namespace and finalizers
    if kubectl get ns cattle-system &>/dev/null 2>&1; then
        # Remove finalizers first to avoid hanging namespace deletion
        kubectl get namespace cattle-system -o json 2>/dev/null \
            | python3 -c "import sys, json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
            | kubectl replace --raw "/api/v1/namespaces/cattle-system/finalize" -f - &>/dev/null 2>&1 || true

        kubectl delete ns cattle-system --ignore-not-found=true --timeout=60s 2>/dev/null || \
            log_warn "cattle-system namespace deletion timed out (finalizers may still be running)"
        log_ok "cattle-system namespace removed"
    fi

    # Remove fleet and Rancher CRDs
    for crd_pattern in "cattle" "rancher" "fleet"; do
        local crds
        crds=$(kubectl get crd 2>/dev/null | grep "${crd_pattern}" | awk '{print $1}' || true)
        if [[ -n "${crds}" ]]; then
            echo "${crds}" | xargs kubectl delete crd --ignore-not-found=true 2>/dev/null || true
            log_ok "Removed ${crd_pattern} CRDs"
        fi
    done

    # Remove Rancher-related namespaces
    for ns in cattle-fleet-system cattle-fleet-local-system fleet-system; do
        kubectl delete ns "${ns}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
    done
    log_ok "Rancher-related namespaces cleaned"

    # Clear step marker
    rm -f "${STEP_DIR}/rancher-install" 2>/dev/null || true
    log_ok "Rancher rollback complete"
}

# =============================================================================
# Remove Traefik Helm Release
# =============================================================================
remove_traefik() {
    log_step "Removing Traefik Helm Release"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if helm -n kube-system list 2>/dev/null | grep -q "traefik"; then
        helm uninstall traefik -n kube-system --timeout 60s 2>&1 || \
            log_warn "helm uninstall traefik failed — may already be removed"
        log_ok "Traefik Helm release uninstalled"
    else
        log_warn "Traefik Helm release not found — skipping"
    fi

    # Remove Traefik CRDs
    local traefik_crds
    traefik_crds=$(kubectl get crd 2>/dev/null | grep "traefik" | awk '{print $1}' || true)
    if [[ -n "${traefik_crds}" ]]; then
        echo "${traefik_crds}" | xargs kubectl delete crd --ignore-not-found=true 2>/dev/null || true
        log_ok "Traefik CRDs removed"
    fi

    rm -f "${STEP_DIR}/traefik-install" 2>/dev/null || true
    log_ok "Traefik rollback complete"
}

# =============================================================================
# Remove cert-manager Helm Release
# =============================================================================
remove_cert_manager() {
    log_step "Removing cert-manager Helm Release"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if helm -n cert-manager list 2>/dev/null | grep -q "cert-manager"; then
        helm uninstall cert-manager -n cert-manager --timeout 60s 2>&1 || \
            log_warn "helm uninstall cert-manager failed — may already be removed"
        log_ok "cert-manager Helm release uninstalled"
    else
        log_warn "cert-manager Helm release not found — skipping"
    fi

    # Remove cert-manager namespace
    if kubectl get ns cert-manager &>/dev/null 2>&1; then
        kubectl delete ns cert-manager --ignore-not-found=true --timeout=60s 2>/dev/null || true
        log_ok "cert-manager namespace removed"
    fi

    # Remove cert-manager CRDs
    local cm_crds
    cm_crds=$(kubectl get crd 2>/dev/null | grep "cert-manager\|certmanager\|jetstack" | awk '{print $1}' || true)
    if [[ -n "${cm_crds}" ]]; then
        echo "${cm_crds}" | xargs kubectl delete crd --ignore-not-found=true 2>/dev/null || true
        log_ok "cert-manager CRDs removed"
    fi

    rm -f "${STEP_DIR}/cert-manager-install" 2>/dev/null || true
    log_ok "cert-manager rollback complete"
}

# =============================================================================
# Remove Certificates
# =============================================================================
remove_certs() {
    log_step "Removing TLS Certificates"

    # Remove cert files
    if [[ -d /opt/rancher-certs ]]; then
        rm -rf /opt/rancher-certs
        log_ok "/opt/rancher-certs/ removed"
    else
        log_warn "/opt/rancher-certs/ not found — skipping"
    fi

    # Remove from system trust store
    if [[ -f /usr/local/share/ca-certificates/rancher-root-ca.crt ]]; then
        rm -f /usr/local/share/ca-certificates/rancher-root-ca.crt
        update-ca-certificates &>/dev/null
        log_ok "Rancher root CA removed from system trust store"
    fi

    rm -f "${STEP_DIR}/certificates-generated" 2>/dev/null || true
    rm -f "${STEP_DIR}/tls-secret-created" 2>/dev/null || true
    log_ok "Certificate rollback complete"
}

# =============================================================================
# Remove K3s Server
# =============================================================================
remove_k3s() {
    log_step "Removing K3s Server"

    # Stop K3s service
    if systemctl is-active --quiet k3s 2>/dev/null; then
        systemctl stop k3s
        log_ok "K3s service stopped"
    fi

    # Run K3s killall script
    if [[ -f /usr/local/bin/k3s-killall.sh ]]; then
        /usr/local/bin/k3s-killall.sh 2>/dev/null || true
        log_ok "k3s-killall.sh executed"
    fi

    # Run K3s uninstall script
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        log_ok "k3s-uninstall.sh executed"
    fi

    # Remove remaining files
    rm -f /usr/local/bin/k3s
    rm -f /usr/local/bin/kubectl
    rm -f /usr/local/bin/helm
    rm -f /usr/local/bin/crictl
    rm -f /usr/local/bin/ctr
    rm -rf /var/lib/rancher/
    rm -rf /etc/rancher/
    rm -f /etc/systemd/system/k3s.service
    rm -f /etc/systemd/system/k3s.service.env
    systemctl daemon-reload 2>/dev/null || true
    log_ok "K3s binaries and data removed"

    # Remove KUBECONFIG from environment files
    sed -i '/KUBECONFIG/d' /etc/environment 2>/dev/null || true
    sed -i '/KUBECONFIG/d' /etc/profile.d/k3s-kubectl.sh 2>/dev/null || true
    rm -f /etc/profile.d/k3s-kubectl.sh 2>/dev/null || true
    rm -rf /root/.kube 2>/dev/null || true
    rm -rf /home/ubuntu/.kube 2>/dev/null || true
    log_ok "KUBECONFIG env vars cleaned"

    # Clear step markers
    rm -f "${STEP_DIR}/k3s-files-prepared" \
          "${STEP_DIR}/k3s-server-install" \
          "${STEP_DIR}/kubectl-config" \
          "${STEP_DIR}/rancher-images-loaded" 2>/dev/null || true

    log_ok "K3s rollback complete"
}

# =============================================================================
# Wipe Logs (--all only)
# =============================================================================
wipe_logs() {
    log_step "Wiping Installation Logs and Step Markers"

    if [[ -d "${LOG_DIR}" ]]; then
        rm -rf "${LOG_DIR}"
        log_ok "${LOG_DIR}/ wiped"
    fi
}

# =============================================================================
# Print Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}  ┌──────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}  │         Rancher Rollback Complete         │${NC}"
    echo -e "${GREEN}  └──────────────────────────────────────────┘${NC}"
    echo ""

    if [[ "${REMOVE_K3S}" == "true" ]]; then
        log_info "VM is restored to pre-install state."
        log_info "To reinstall Rancher:"
        echo ""
        echo -e "    ${YELLOW}sudo ./install-rancher.sh \\${NC}"
        echo -e "    ${YELLOW}  --bundle-path /opt/offline-bundle \\${NC}"
        echo -e "    ${YELLOW}  --rancher-ip <IP> \\${NC}"
        echo -e "    ${YELLOW}  --bootstrap-password changeme${NC}"
    else
        log_info "K3s is still running. Components removed:"
        [[ "${REMOVE_RANCHER}"      == "true" ]] && log_info "  ✔ Rancher"
        [[ "${REMOVE_TRAEFIK}"      == "true" ]] && log_info "  ✔ Traefik"
        [[ "${REMOVE_CERT_MANAGER}" == "true" ]] && log_info "  ✔ cert-manager"
        [[ "${REMOVE_CERTS}"        == "true" ]] && log_info "  ✔ Certificates"
        echo ""
        log_info "To reinstall components, re-run install-rancher.sh:"
        echo -e "    ${YELLOW}sudo ./install-rancher.sh ...${NC}"
    fi
    echo ""
}

# =============================================================================
# Header
# =============================================================================
print_header() {
    echo ""
    echo -e "${BLUE}  ┌───────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}  │          Rancher Server Rollback               │${NC}"
    echo -e "${BLUE}  │      Restore VM to Pre-Install State           │${NC}"
    echo -e "${BLUE}  └───────────────────────────────────────────────┘${NC}"
    echo ""

    log_info "Rollback scope:"
    [[ "${REMOVE_RANCHER}"       == "true" ]] && log_info "  rancher=true"
    [[ "${REMOVE_TRAEFIK}"       == "true" ]] && log_info "  traefik=true"
    [[ "${REMOVE_CERT_MANAGER}"  == "true" ]] && log_info "  cert-manager=true"
    [[ "${REMOVE_K3S}"           == "true" ]] && log_info "  k3s=true"
    [[ "${REMOVE_CERTS}"         == "true" ]] && log_info "  certs=true"
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Ensure log dir exists for early logging
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    parse_args "$@"
    print_header
    confirm

    # Execute in correct tear-down order:
    # Rancher → Traefik → cert-manager → Certs → K3s → Logs
    [[ "${REMOVE_RANCHER}"      == "true" ]] && remove_rancher
    [[ "${REMOVE_TRAEFIK}"      == "true" ]] && remove_traefik
    [[ "${REMOVE_CERT_MANAGER}" == "true" ]] && remove_cert_manager
    [[ "${REMOVE_CERTS}"        == "true" ]] && remove_certs
    [[ "${REMOVE_K3S}"          == "true" ]] && remove_k3s

    # Wipe logs only on --all (after everything else is done)
    [[ "${REMOVE_ALL}"          == "true" ]] && wipe_logs

    print_summary
}

main "$@"
