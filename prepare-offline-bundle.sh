#!/usr/bin/env bash
# =============================================================================
# prepare-offline-bundle.sh
#
# Production-grade script to prepare a complete offline bundle for deploying
# a secure K3s cluster with Cilium CNI and WireGuard encryption.
#
# Run this script on an internet-connected Linux machine.
# Transfer the generated bundle to your air-gapped environment.
#
# Usage: ./prepare-offline-bundle.sh [OPTIONS]
#   --output-dir DIR     Output directory          (default: ./offline-bundle)
#   --skip-images        Skip Docker image pull/save
#   --skip-packages      Skip Ubuntu .deb package download
#   -h, --help           Show this help message
#
# Environment overrides (versions):
#   K3S_VERSION, CILIUM_VERSION, HELM_VERSION, KUBECTL_VERSION, CRICTL_VERSION
# =============================================================================

set -euo pipefail

# =============================================================================
# Color Codes
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Versions  (all overridable via environment variables)
#
# Compatibility matrix (verified March 2026):
#   K3s v1.34.5+k3s1  →  Kubernetes v1.34.5
#   Cilium 1.19.1      →  certified for Kubernetes 1.31–1.34  ✔
#   kubectl v1.34.5    →  exact match to K3s Kubernetes version (zero skew)
#   crictl v1.35.0     →  within ±1 minor skew policy with K3s 1.34  ✔
#   Helm v3.20.0       →  latest Helm v3 (v4 has breaking API changes, skip)
#   cert-manager v1.19.4 → certified for Kubernetes 1.31–1.35  ✔
#   Hubble UI/Backend v0.13.3 → chart-pinned by Cilium 1.19.1 values.yaml
#   Cilium certgen v0.3.2    → chart-pinned by Cilium 1.19.1 values.yaml
#   Traefik chart 39.0.4     → latest, bundles Traefik v3.6.9
#
# NOTE: Do NOT upgrade K3s to v1.35 while keeping Cilium 1.19.1.
#       Cilium 1.20 (pre-release only) adds certified K8s 1.35 support.
# =============================================================================
K3S_VERSION="${K3S_VERSION:-v1.34.5+k3s1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.1}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.19.2}"
HELM_VERSION="${HELM_VERSION:-v3.20.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.34.5}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.35.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.4}"
HUBBLE_UI_VERSION="${HUBBLE_UI_VERSION:-v0.13.3}"
HUBBLE_UI_BACKEND_VERSION="${HUBBLE_UI_BACKEND_VERSION:-v0.13.3}"
CILIUM_CERTGEN_VERSION="${CILIUM_CERTGEN_VERSION:-v0.3.2}"
ETCD_VERSION="${ETCD_VERSION:-v3.5.17}"
RANCHER_VERSION="${RANCHER_VERSION:-2.13.2}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-39.0.0}"

# =============================================================================
# Configuration
# =============================================================================
OUTPUT_DIR="${OUTPUT_DIR:-./offline-bundle}"
BUNDLE_ARCHIVE="${BUNDLE_ARCHIVE:-./offline-bundle.tar.gz}"
LOG_DIR=""          # set after OUTPUT_DIR is finalised
LOG_FILE=""         # set after OUTPUT_DIR is finalised
MAX_RETRIES=3
RETRY_DELAY=5

SKIP_IMAGES="${SKIP_IMAGES:-false}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_RANCHER="${SKIP_RANCHER:-false}"

# Runtime counters
STATS_IMAGES=0
STATS_BINARIES=0
STATS_PACKAGES=0
STATS_CHARTS=0

# =============================================================================
# Logging (timestamps + colour + file sink)
# =============================================================================
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { local m="$*"; echo -e "${GREEN}[INFO]${NC}  $(_ts) ${m}";            [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [INFO]  ${m}" >> "${LOG_FILE}"; }
log_warn()  { local m="$*"; echo -e "${YELLOW}[WARN]${NC}  $(_ts) ${m}";           [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [WARN]  ${m}" >> "${LOG_FILE}"; }
log_error() { local m="$*"; echo -e "${RED}[ERROR]${NC} $(_ts) ${m}" >&2;          [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [ERROR] ${m}" >> "${LOG_FILE}"; }
log_step()  { local m="$*"; echo -e "\n${BLUE}${BOLD}══ [STEP] $(_ts) ${m}${NC}";  [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [STEP]  ${m}" >> "${LOG_FILE}"; }
log_ok()    { local m="$*"; echo -e "${GREEN}  ✔${NC} ${m}";                        [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [OK]    ${m}" >> "${LOG_FILE}"; }
log_skip()  { local m="$*"; echo -e "${CYAN}  ↷${NC} ${m} (skipped)";              [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [SKIP]  ${m}" >> "${LOG_FILE}"; }
log_debug() { local m="$*";                                                          [[ -n "${LOG_FILE}" ]] && echo "[$(_ts)] [DEBUG] ${m}" >> "${LOG_FILE}"; }

on_error() {
    local line="$1"
    log_error "Script failed at line ${line}."
    [[ -n "${LOG_FILE}" ]] && log_error "Full details in: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}prepare-offline-bundle.sh${NC} — K3s + Cilium + WireGuard Offline Bundle Preparer

${BOLD}USAGE${NC}
  $0 [OPTIONS]

${BOLD}OPTIONS${NC}
  --output-dir DIR     Write artifacts to DIR            (default: ./offline-bundle)
  --skip-images        Skip container image pull/save
  --skip-packages      Skip Ubuntu .deb package download
  -h, --help           Show this help and exit

${BOLD}ENVIRONMENT VARIABLES (version overrides)${NC}
  K3S_VERSION          (default: ${K3S_VERSION})
  CILIUM_VERSION       (default: ${CILIUM_VERSION})
  CILIUM_CLI_VERSION   (default: ${CILIUM_CLI_VERSION})
  HELM_VERSION         (default: ${HELM_VERSION})
  KUBECTL_VERSION      (default: ${KUBECTL_VERSION})
  CRICTL_VERSION       (default: ${CRICTL_VERSION})
  CERT_MANAGER_VERSION  (default: ${CERT_MANAGER_VERSION})
  ETCD_VERSION          (default: ${ETCD_VERSION})
  RANCHER_VERSION       (default: ${RANCHER_VERSION})
  TRAEFIK_CHART_VERSION (default: ${TRAEFIK_CHART_VERSION})

${BOLD}EXAMPLES${NC}
  # Full bundle including Rancher (default)
  $0

  # Skip Docker images for a quick test
  $0 --skip-images

  # Skip Rancher components (K3s workload cluster only)
  $0 --skip-rancher

  # Custom output directory
  $0 --output-dir /mnt/usb/k3s-bundle

  # Override K3s version
  K3S_VERSION=v1.29.5+k3s1 $0

${BOLD}OUTPUT STRUCTURE${NC}
  offline-bundle/
  ├── images/           K3s airgap + Cilium + cert-manager tarballs
  ├── binaries/         k3s, kubectl, helm, cilium CLI, crictl, install.sh
  ├── packages/         Ubuntu .deb packages + dependencies
  ├── helm-charts/      Cilium + cert-manager Helm charts
  ├── manifests/        Configuration templates (cilium-values, k3s env, policies)
  ├── checksums/        sha256sums.txt for all artifacts
  ├── metadata/         architecture.txt, version-info.txt
  └── logs/             resource-preparation.log

  offline-bundle.tar.gz — final compressed archive
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)
                OUTPUT_DIR="${2:?--output-dir requires a value}"
                BUNDLE_ARCHIVE="${OUTPUT_DIR%/}.tar.gz"
                shift 2
                ;;
            --skip-images)
                SKIP_IMAGES="true"
                shift
                ;;
            --skip-packages)
                SKIP_PACKAGES="true"
                shift
                ;;
            --skip-rancher)
                SKIP_RANCHER="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Update derived paths after all arguments are parsed
    LOG_DIR="${OUTPUT_DIR}/logs"
    LOG_FILE="${LOG_DIR}/resource-preparation.log"
}

# =============================================================================
# 1. Architecture Detection
# =============================================================================
detect_architecture() {
    log_step "Architecture Detection"

    local raw_arch
    raw_arch="$(uname -m)"

    case "${raw_arch}" in
        x86_64 | amd64)
            ARCH="amd64"
            K3S_BINARY_NAME="k3s"
            ;;
        aarch64 | arm64)
            ARCH="arm64"
            K3S_BINARY_NAME="k3s-arm64"
            ;;
        *)
            log_error "Unsupported architecture: ${raw_arch}"
            log_error "Supported: x86_64/amd64, aarch64/arm64"
            exit 1
            ;;
    esac

    DOCKER_PLATFORM="linux/${ARCH}"

    log_ok "Raw architecture  : ${raw_arch}"
    log_ok "Normalized arch   : ${ARCH}"
    log_ok "Docker platform   : ${DOCKER_PLATFORM}"
    log_ok "K3s binary name   : ${K3S_BINARY_NAME}"

    # Write early so metadata is available throughout the run
    mkdir -p "${OUTPUT_DIR}/metadata"
    {
        echo "Host architecture (raw): ${raw_arch}"
        echo "Normalized architecture: ${ARCH}"
        echo "Docker platform        : ${DOCKER_PLATFORM}"
        echo "OS                     : $(uname -s)"
        echo "Kernel                 : $(uname -r)"
        echo "Hostname               : $(hostname)"
        echo "Bundle generated at    : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "${OUTPUT_DIR}/metadata/architecture.txt"
}

# =============================================================================
# Directory Creation
# =============================================================================
create_directories() {
    log_step "Creating output directory structure"

    mkdir -p \
        "${OUTPUT_DIR}/images" \
        "${OUTPUT_DIR}/binaries" \
        "${OUTPUT_DIR}/packages" \
        "${OUTPUT_DIR}/helm-charts" \
        "${OUTPUT_DIR}/manifests" \
        "${OUTPUT_DIR}/checksums" \
        "${OUTPUT_DIR}/metadata" \
        "${LOG_DIR}"

    log_ok "Directories created under: ${OUTPUT_DIR}"
}

# =============================================================================
# Requirement Check
# =============================================================================
check_requirements() {
    log_step "Checking required tools"

    local required=("curl" "tar" "sha256sum" "helm" "file" "jq")
    [[ "${SKIP_IMAGES}" != "true" ]] && required+=("docker")

    local missing=0
    for cmd in "${required[@]}"; do
        if command -v "${cmd}" &>/dev/null; then
            log_ok "${cmd} → $(command -v "${cmd}")"
        else
            log_error "Missing required command: ${cmd}"
            missing=$((missing + 1))
        fi
    done

    if [[ "${SKIP_IMAGES}" != "true" ]]; then
        if ! docker info &>/dev/null; then
            log_error "Docker daemon is not reachable. Start Docker or use --skip-images."
            missing=$((missing + 1))
        else
            log_ok "Docker daemon is reachable"
        fi
    fi

    if [[ "${missing}" -gt 0 ]]; then
        log_error "${missing} required tool(s) are missing. Install them and re-run."
        exit 1
    fi

    log_ok "All required tools present"
}

# =============================================================================
# Download Utility — retry logic + idempotency + optional checksum verify
# =============================================================================
download_file() {
    local url="$1"
    local out="$2"
    local expected_sha256="${3:-}"

    # Idempotency: if the file already exists, verify checksum (if provided) or skip
    if [[ -f "${out}" ]]; then
        if [[ -n "${expected_sha256}" ]]; then
            local actual_sha256
            actual_sha256="$(sha256sum "${out}" | awk '{print $1}')"
            if [[ "${actual_sha256}" == "${expected_sha256}" ]]; then
                log_skip "$(basename "${out}") (checksum verified)"
                return 0
            else
                log_warn "Checksum mismatch for $(basename "${out}") — re-downloading"
                rm -f "${out}"
            fi
        else
            log_skip "$(basename "${out}")"
            return 0
        fi
    fi

    log_debug "URL: ${url}"

    local attempt=0
    while [[ ${attempt} -lt ${MAX_RETRIES} ]]; do
        attempt=$((attempt + 1))
        log_info "  [attempt ${attempt}/${MAX_RETRIES}] $(basename "${out}")"

        if curl -fL \
                --retry 2 \
                --retry-delay 3 \
                --connect-timeout 15 \
                --progress-bar \
                -o "${out}" \
                "${url}" 2>>"${LOG_FILE}"; then

            local size
            size="$(du -sh "${out}" | awk '{print $1}')"
            log_ok "$(basename "${out}") — ${size}"
            return 0
        fi

        log_warn "Attempt ${attempt} failed for $(basename "${out}")"
        [[ ${attempt} -lt ${MAX_RETRIES} ]] && sleep "${RETRY_DELAY}"
    done

    log_error "Failed after ${MAX_RETRIES} attempts: ${url}"
    return 1
}

# =============================================================================
# 4. K3s Binary + Airgap Images + Install Script
# =============================================================================
download_k3s_components() {
    log_step "K3s Components  (version: ${K3S_VERSION})"

    local base_url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
    local airgap_file="k3s-airgap-images-${ARCH}.tar.gz"

    # K3s binary
    download_file \
        "${base_url}/${K3S_BINARY_NAME}" \
        "${OUTPUT_DIR}/binaries/k3s"
    chmod +x "${OUTPUT_DIR}/binaries/k3s"
    STATS_BINARIES=$((STATS_BINARIES + 1))

    # Offline install script
    download_file \
        "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" \
        "${OUTPUT_DIR}/binaries/install.sh"
    chmod +x "${OUTPUT_DIR}/binaries/install.sh"

    # K3s built-in airgap image bundle (pause, CoreDNS, metrics-server, etc.)
    download_file \
        "${base_url}/${airgap_file}" \
        "${OUTPUT_DIR}/images/${airgap_file}"
    STATS_IMAGES=$((STATS_IMAGES + 1))
}

# =============================================================================
# 4. Platform Binaries — kubectl, helm, crictl, cilium CLI
# =============================================================================
download_binaries() {
    log_step "Platform Binaries  (kubectl, helm, crictl, cilium CLI)"

    # ── kubectl ──────────────────────────────────────────────────────────────
    download_file \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
        "${OUTPUT_DIR}/binaries/kubectl"
    chmod +x "${OUTPUT_DIR}/binaries/kubectl"
    STATS_BINARIES=$((STATS_BINARIES + 1))

    # ── Helm ─────────────────────────────────────────────────────────────────
    local helm_tarball="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    if [[ ! -f "${OUTPUT_DIR}/binaries/helm" ]]; then
        download_file \
            "https://get.helm.sh/${helm_tarball}" \
            "${OUTPUT_DIR}/binaries/${helm_tarball}"

        tar -xzf "${OUTPUT_DIR}/binaries/${helm_tarball}" \
            -C "${OUTPUT_DIR}/binaries" \
            "linux-${ARCH}/helm"

        mv "${OUTPUT_DIR}/binaries/linux-${ARCH}/helm" \
           "${OUTPUT_DIR}/binaries/helm"

        rm -rf "${OUTPUT_DIR}/binaries/linux-${ARCH}" \
               "${OUTPUT_DIR}/binaries/${helm_tarball}"
    else
        log_skip "helm binary"
    fi
    chmod +x "${OUTPUT_DIR}/binaries/helm"
    STATS_BINARIES=$((STATS_BINARIES + 1))

    # ── crictl ───────────────────────────────────────────────────────────────
    local crictl_tarball="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    if [[ ! -f "${OUTPUT_DIR}/binaries/crictl" ]]; then
        download_file \
            "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${crictl_tarball}" \
            "${OUTPUT_DIR}/binaries/${crictl_tarball}"

        tar -xzf "${OUTPUT_DIR}/binaries/${crictl_tarball}" \
            -C "${OUTPUT_DIR}/binaries" crictl

        rm -f "${OUTPUT_DIR}/binaries/${crictl_tarball}"
    else
        log_skip "crictl binary"
    fi
    chmod +x "${OUTPUT_DIR}/binaries/crictl"
    STATS_BINARIES=$((STATS_BINARIES + 1))

    # ── Cilium CLI ────────────────────────────────────────────────────────────
    local cilium_cli_tarball="cilium-linux-${ARCH}.tar.gz"
    if [[ ! -f "${OUTPUT_DIR}/binaries/cilium" ]]; then
        download_file \
            "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${cilium_cli_tarball}" \
            "${OUTPUT_DIR}/binaries/${cilium_cli_tarball}"

        tar -xzf "${OUTPUT_DIR}/binaries/${cilium_cli_tarball}" \
            -C "${OUTPUT_DIR}/binaries" cilium

        rm -f "${OUTPUT_DIR}/binaries/${cilium_cli_tarball}"
    else
        log_skip "cilium CLI binary"
    fi
    chmod +x "${OUTPUT_DIR}/binaries/cilium"
    STATS_BINARIES=$((STATS_BINARIES + 1))

    # ── etcd + etcdctl ───────────────────────────────────────────────────────
    local etcd_tarball="etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
    if [[ ! -f "${OUTPUT_DIR}/binaries/etcd" ]] || [[ ! -f "${OUTPUT_DIR}/binaries/etcdctl" ]]; then
        download_file \
            "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${etcd_tarball}" \
            "${OUTPUT_DIR}/binaries/${etcd_tarball}"

        # Extract only etcd and etcdctl from the tarball (directory prefix varies by version)
        tar -xzf "${OUTPUT_DIR}/binaries/${etcd_tarball}" \
            -C "${OUTPUT_DIR}/binaries" \
            --wildcards \
            --strip-components=1 \
            "*/etcd" "*/etcdctl"

        rm -f "${OUTPUT_DIR}/binaries/${etcd_tarball}"
        log_ok "etcd ${ETCD_VERSION} extracted"
    else
        log_skip "etcd + etcdctl binaries"
    fi
    chmod +x "${OUTPUT_DIR}/binaries/etcd" "${OUTPUT_DIR}/binaries/etcdctl"
    STATS_BINARIES=$((STATS_BINARIES + 2))
}

# =============================================================================
# 3. Container Image Collection — pull + save as tar archives
# =============================================================================
pull_and_save_images() {
    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log_warn "Container image download skipped (--skip-images)"
        return
    fi

    log_step "Container Image Collection  (platform: ${DOCKER_PLATFORM})"

    # ── Cilium + Hubble images ────────────────────────────────────────────────
    local cilium_images=(
        "quay.io/cilium/cilium:v${CILIUM_VERSION}"
        "quay.io/cilium/operator-generic:v${CILIUM_VERSION}"
        "quay.io/cilium/hubble-relay:v${CILIUM_VERSION}"
        "quay.io/cilium/hubble-ui:${HUBBLE_UI_VERSION}"
        "quay.io/cilium/hubble-ui-backend:${HUBBLE_UI_BACKEND_VERSION}"
        "quay.io/cilium/certgen:${CILIUM_CERTGEN_VERSION}"
    )

    if [[ ! -f "${OUTPUT_DIR}/images/cilium-images.tar" ]]; then
        log_info "Pulling Cilium + Hubble images..."
        for image in "${cilium_images[@]}"; do
            log_info "  docker pull --platform ${DOCKER_PLATFORM} ${image}"
            docker pull --platform "${DOCKER_PLATFORM}" "${image}"
        done

        log_info "Saving to cilium-images.tar ..."
        docker save -o "${OUTPUT_DIR}/images/cilium-images.tar" "${cilium_images[@]}"
        log_ok "cilium-images.tar — $(du -sh "${OUTPUT_DIR}/images/cilium-images.tar" | awk '{print $1}')"
    else
        log_skip "cilium-images.tar"
    fi
    STATS_IMAGES=$((STATS_IMAGES + 1))

    # ── cert-manager images ───────────────────────────────────────────────────
    local certmanager_images=(
        "quay.io/jetstack/cert-manager-controller:${CERT_MANAGER_VERSION}"
        "quay.io/jetstack/cert-manager-cainjector:${CERT_MANAGER_VERSION}"
        "quay.io/jetstack/cert-manager-webhook:${CERT_MANAGER_VERSION}"
    )

    if [[ ! -f "${OUTPUT_DIR}/images/cert-manager-images.tar" ]]; then
        log_info "Pulling cert-manager images..."
        for image in "${certmanager_images[@]}"; do
            log_info "  docker pull --platform ${DOCKER_PLATFORM} ${image}"
            docker pull --platform "${DOCKER_PLATFORM}" "${image}"
        done

        log_info "Saving to cert-manager-images.tar ..."
        docker save -o "${OUTPUT_DIR}/images/cert-manager-images.tar" "${certmanager_images[@]}"
        log_ok "cert-manager-images.tar — $(du -sh "${OUTPUT_DIR}/images/cert-manager-images.tar" | awk '{print $1}')"
    else
        log_skip "cert-manager-images.tar"
    fi
    STATS_IMAGES=$((STATS_IMAGES + 1))

    # ── Rancher images ─────────────────────────────────────────────────────────
    if [[ "${SKIP_RANCHER}" == "true" ]]; then
        log_skip "rancher-images.tar (--skip-rancher)"
        return
    fi

    local rancher_images=(
        "rancher/rancher:v${RANCHER_VERSION}"
        "rancher/rancher-agent:v${RANCHER_VERSION}"
        "rancher/rancher-webhook:v0.7.2"
        "rancher/shell:v0.2.2"
        "rancher/gitjob:v0.9.11"
        "rancher/fleet-agent:v0.11.2"
        "rancher/fleet:v0.11.2"
        "traefik:v3.3.6"
        "traefik/whoami:v1.10.0"
        "quay.io/jetstack/cert-manager-controller:v1.14.0"
        "quay.io/jetstack/cert-manager-cainjector:v1.14.0"
        "quay.io/jetstack/cert-manager-webhook:v1.14.0"
    )

    if [[ ! -f "${OUTPUT_DIR}/images/rancher-images.tar" ]]; then
        log_info "Pulling Rancher images (this may take several minutes)..."
        for image in "${rancher_images[@]}"; do
            log_info "  docker pull --platform ${DOCKER_PLATFORM} ${image}"
            docker pull --platform "${DOCKER_PLATFORM}" "${image}" || \
                log_warn "  Failed to pull ${image} — skipping"
        done

        log_info "Saving to rancher-images.tar ..."
        docker save -o "${OUTPUT_DIR}/images/rancher-images.tar" "${rancher_images[@]}"
        log_ok "rancher-images.tar — $(du -sh "${OUTPUT_DIR}/images/rancher-images.tar" | awk '{print $1}')"
    else
        log_skip "rancher-images.tar"
    fi
    STATS_IMAGES=$((STATS_IMAGES + 1))
}

# =============================================================================
# 5. System Package Download  (Ubuntu/Debian only)
# =============================================================================
download_packages() {
    if [[ "${SKIP_PACKAGES}" == "true" ]]; then
        log_warn "Package download skipped (--skip-packages)"
        return
    fi

    if ! command -v apt-get &>/dev/null; then
        log_warn "apt-get not found — package download skipped (non-Ubuntu/Debian host)"
        return
    fi

    log_step "Ubuntu Package Download (.deb)"

    local packages=(
        "iproute2"
        "conntrack"
        "iptables"
        "ipset"
        "curl"
        "socat"
        "jq"
        "tar"
        "unzip"
        "wget"
        "wireguard"
        "wireguard-tools"
        "ethtool"
        "ebtables"
        "bpfcc-tools"
    )

    log_info "Running apt-get update..."
    sudo apt-get update -qq 2>>"${LOG_FILE}" || log_warn "apt-get update had issues (may be expected)"

    log_info "Downloading packages: ${packages[*]}"
    (
        cd "${OUTPUT_DIR}/packages" || { log_error "Cannot cd to packages dir"; return 1; }
        # Download named packages
        sudo apt-get download "${packages[@]}" 2>>"${LOG_FILE}" \
            || log_warn "Some packages may be unavailable on this host OS version"

        # Resolve and download dependency .debs
        log_info "Resolving and downloading package dependencies..."
        sudo apt-get install --print-uris -qq "${packages[@]}" 2>/dev/null \
            | grep "^'" \
            | awk -F"'" '{print $2}' \
            | while read -r dep_url; do
                local dep_file
                dep_file="$(basename "${dep_url}")"
                if [[ ! -f "${dep_file}" ]]; then
                    curl -fsSL -o "${dep_file}" "${dep_url}" \
                        2>>"${LOG_FILE}" || true
                fi
              done
    )

    STATS_PACKAGES=$(find "${OUTPUT_DIR}/packages" -name "*.deb" 2>/dev/null | wc -l)
    log_ok "Downloaded ${STATS_PACKAGES} .deb package(s)"
}

# =============================================================================
# 6. Helm Charts
# =============================================================================
download_helm_charts() {
    log_step "Helm Chart Download"

    log_info "Adding Helm repositories..."
    helm repo add cilium   https://helm.cilium.io/          --force-update &>/dev/null
    helm repo add jetstack https://charts.jetstack.io       --force-update &>/dev/null
    helm repo update &>/dev/null
    log_ok "Helm repos updated"

    # Cilium chart
    local cilium_chart="${OUTPUT_DIR}/helm-charts/cilium-${CILIUM_VERSION}.tgz"
    if [[ ! -f "${cilium_chart}" ]]; then
        log_info "Pulling Cilium chart v${CILIUM_VERSION}..."
        helm pull cilium/cilium \
            --version "${CILIUM_VERSION}" \
            --destination "${OUTPUT_DIR}/helm-charts"
        log_ok "cilium-${CILIUM_VERSION}.tgz"
    else
        log_skip "cilium-${CILIUM_VERSION}.tgz"
    fi
    STATS_CHARTS=$((STATS_CHARTS + 1))

    # cert-manager chart
    local cm_chart="${OUTPUT_DIR}/helm-charts/cert-manager-${CERT_MANAGER_VERSION}.tgz"
    if [[ ! -f "${cm_chart}" ]]; then
        log_info "Pulling cert-manager chart ${CERT_MANAGER_VERSION}..."
        helm pull jetstack/cert-manager \
            --version "${CERT_MANAGER_VERSION}" \
            --destination "${OUTPUT_DIR}/helm-charts"
        log_ok "cert-manager-${CERT_MANAGER_VERSION}.tgz"
    else
        log_skip "cert-manager-${CERT_MANAGER_VERSION}.tgz"
    fi
    STATS_CHARTS=$((STATS_CHARTS + 1))

    # ── Rancher charts (only if --skip-rancher not set) ───────────────────────
    if [[ "${SKIP_RANCHER}" == "true" ]]; then
        log_skip "Rancher + Traefik charts (--skip-rancher)"
        return
    fi

    # Traefik chart (for Rancher ingress)
    helm repo add traefik https://helm.traefik.io/traefik --force-update &>/dev/null
    helm repo update &>/dev/null

    local traefik_chart="${OUTPUT_DIR}/helm-charts/traefik-${TRAEFIK_CHART_VERSION}.tgz"
    if [[ ! -f "${traefik_chart}" ]]; then
        log_info "Pulling Traefik chart v${TRAEFIK_CHART_VERSION}..."
        helm pull traefik/traefik \
            --version "${TRAEFIK_CHART_VERSION}" \
            --destination "${OUTPUT_DIR}/helm-charts"
        log_ok "traefik-${TRAEFIK_CHART_VERSION}.tgz"
    else
        log_skip "traefik-${TRAEFIK_CHART_VERSION}.tgz"
    fi
    STATS_CHARTS=$((STATS_CHARTS + 1))

    # Rancher chart
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update &>/dev/null
    helm repo update &>/dev/null

    local rancher_chart="${OUTPUT_DIR}/helm-charts/rancher-${RANCHER_VERSION}.tgz"
    if [[ ! -f "${rancher_chart}" ]]; then
        log_info "Pulling Rancher chart v${RANCHER_VERSION}..."
        helm pull rancher-stable/rancher \
            --version "${RANCHER_VERSION}" \
            --destination "${OUTPUT_DIR}/helm-charts"
        log_ok "rancher-${RANCHER_VERSION}.tgz"
    else
        log_skip "rancher-${RANCHER_VERSION}.tgz"
    fi
    STATS_CHARTS=$((STATS_CHARTS + 1))
}

# =============================================================================
# 7. Configuration Templates (manifests/)
# =============================================================================
create_manifests() {
    log_step "Writing Configuration Templates"

    # ── Cilium Helm values ────────────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/cilium-values.yaml" <<EOF
# ============================================================
# Cilium Helm values — K3s + WireGuard offline installation
# Generated by prepare-offline-bundle.sh
# Cilium version: ${CILIUM_VERSION}
# ============================================================
# NOTE: Replace CHANGE_ME_CONTROL_PLANE_IP with actual IP.

image:
  pullPolicy: Never          # Use only locally loaded images — offline mode

ipam:
  mode: kubernetes

# eBPF kube-proxy replacement
kubeProxyReplacement: true
k8sServiceHost: "CHANGE_ME_CONTROL_PLANE_IP"
k8sServicePort: 6443

# WireGuard transparent encryption (pod-to-pod across nodes)
encryption:
  enabled: true
  type: wireguard
  wireguard:
    persistentKeepalive: 0   # Set to 25 if nodes are behind NAT

# Networking
routingMode: tunnel
tunnelProtocol: vxlan
autoDirectNodeRoutes: false
enableIPv4Masquerade: true

bpf:
  masquerade: true

# Service exposure
nodePort:
  enabled: true
hostPort:
  enabled: true
externalIPs:
  enabled: true

# Hubble observability
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enableOpenMetrics: true
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp

# Prometheus metrics
prometheus:
  enabled: true
operator:
  prometheus:
    enabled: true
EOF
    log_ok "manifests/cilium-values.yaml"

    # ── K3s Server env ────────────────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/k3s-server.env" <<'ENVEOF'
# ============================================================
# K3s Control-Plane install environment
# Generated by prepare-offline-bundle.sh
# ============================================================
# Usage:
#   export K3S_NODE_IP="<this-node-IP>"
#   sudo -E bash /opt/offline-bundle/binaries/install.sh \
#     --flannel-backend=none \
#     --disable-network-policy \
#     --disable=traefik \
#     --disable=servicelb \
#     --disable-kube-proxy \
#     --cluster-cidr=10.244.0.0/16 \
#     --service-cidr=10.96.0.0/12 \
#     --cluster-dns=10.96.0.10 \
#     --node-ip=${K3S_NODE_IP} \
#     --tls-san=${K3S_NODE_IP} \
#     --write-kubeconfig-mode=644

export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_BIN_DIR=/usr/local/bin
ENVEOF
    log_ok "manifests/k3s-server.env"

    # ── K3s Agent env ─────────────────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/k3s-agent.env" <<'ENVEOF'
# ============================================================
# K3s Agent (Worker) install environment
# Generated by prepare-offline-bundle.sh
# ============================================================
# Usage:
#   export K3S_NODE_IP="<this-worker-IP>"
#   export K3S_URL="https://<control-plane-IP>:6443"
#   export K3S_TOKEN="<token-from-control-plane>"
#   sudo -E bash /opt/offline-bundle/binaries/install.sh

export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_EXEC=agent
export INSTALL_K3S_BIN_DIR=/usr/local/bin
ENVEOF
    log_ok "manifests/k3s-agent.env"

    # ── Default deny NetworkPolicy ────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/default-deny-networkpolicy.yaml" <<'YMLEOF'
# ============================================================
# Default deny-all + allow-DNS NetworkPolicy
# Apply per namespace:
#   kubectl apply -f default-deny-networkpolicy.yaml -n <namespace>
# ============================================================
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
YMLEOF
    log_ok "manifests/default-deny-networkpolicy.yaml"

    # ── Sysctl configuration ──────────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/99-k3s-cilium.conf" <<'SYSCTL'
# ============================================================
# Sysctl settings for K3s + Cilium + WireGuard nodes
# Copy to: /etc/sysctl.d/99-k3s-cilium.conf
# Apply  : sudo sysctl --system
# ============================================================
net.ipv4.ip_forward                  = 1
net.ipv6.conf.all.forwarding         = 1
net.bridge.bridge-nf-call-iptables   = 1
net.bridge.bridge-nf-call-ip6tables  = 1
net.bridge.bridge-nf-call-arptables  = 1
net.ipv4.conf.all.rp_filter          = 0
net.ipv4.conf.default.rp_filter      = 0
fs.inotify.max_user_instances        = 8192
fs.inotify.max_user_watches          = 524288
net.netfilter.nf_conntrack_max       = 1000000
SYSCTL
    log_ok "manifests/99-k3s-cilium.conf"

    # ── Image load helper script ──────────────────────────────────────────────
    cat > "${OUTPUT_DIR}/manifests/load-images.sh" <<'SCRIPTEOF'
#!/usr/bin/env bash
# ============================================================
# load-images.sh — Import all image tarballs into containerd
# Run on EACH cluster node after extracting the offline bundle.
# ============================================================
set -euo pipefail

BUNDLE_DIR="${1:-/opt/offline-bundle}"
IMAGE_DIR="${BUNDLE_DIR}/images"

echo "[INFO] Loading images from: ${IMAGE_DIR}"

for tarfile in "${IMAGE_DIR}"/*.tar "${IMAGE_DIR}"/*.tar.gz; do
    [[ -f "${tarfile}" ]] || continue
    echo "[INFO] Importing: $(basename "${tarfile}")"
    sudo ctr images import "${tarfile}"
done

echo "[OK] All images imported into containerd."
echo ""
echo "Loaded images:"
sudo ctr images list | grep -v sha256 | awk '{print "  " $1}'
SCRIPTEOF
    chmod +x "${OUTPUT_DIR}/manifests/load-images.sh"
    log_ok "manifests/load-images.sh"
}

# =============================================================================
# Metadata
# =============================================================================
write_metadata() {
    log_step "Writing Metadata"

    cat > "${OUTPUT_DIR}/metadata/version-info.txt" <<EOF
K3s + Cilium + WireGuard Offline Bundle
Generated : $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Host      : $(hostname)

Component Versions
------------------
K3s binary       : ${K3S_VERSION}
Cilium           : ${CILIUM_VERSION}
Cilium CLI       : ${CILIUM_CLI_VERSION}
kubectl          : ${KUBECTL_VERSION}
helm             : ${HELM_VERSION}
crictl           : ${CRICTL_VERSION}
cert-manager     : ${CERT_MANAGER_VERSION}
Hubble UI        : ${HUBBLE_UI_VERSION}
etcd             : ${ETCD_VERSION}
Rancher          : ${RANCHER_VERSION}
Traefik chart    : ${TRAEFIK_CHART_VERSION}

Flags
------------------
Images skipped   : ${SKIP_IMAGES}
Packages skipped : ${SKIP_PACKAGES}
Rancher skipped  : ${SKIP_RANCHER}
EOF
    log_ok "metadata/version-info.txt"
}

# =============================================================================
# 8. Checksum Generation
# =============================================================================
generate_checksums() {
    log_step "Generating SHA256 Checksums"

    local checksum_file="${OUTPUT_DIR}/checksums/sha256sums.txt"
    : > "${checksum_file}"

    local count=0
    for subdir in binaries images packages helm-charts manifests; do
        local full="${OUTPUT_DIR}/${subdir}"
        [[ -d "${full}" ]] || continue
        # Find all files, sort them, and process line by line
        find "${full}" -type f | sort | while IFS= read -r file; do
            local rel="${file#${OUTPUT_DIR}/}"
            sha256sum "${file}" \
                | awk -v r="${rel}" '{printf "%s  %s\n", $1, r}' \
                >> "${checksum_file}"
        done
        # Count files after loop completes
        count=$(grep -c . "${checksum_file}" 2>/dev/null || echo 0)
    done

    log_ok "SHA256 checksums generated for ${count} file(s) → checksums/sha256sums.txt"
}

# =============================================================================
# 8. Bundle Validation
# =============================================================================
validate_bundle() {
    log_step "Bundle Validation"

    local missing=0
    local arch_errors=0

    # Required files
    local required_files=(
        "${OUTPUT_DIR}/binaries/k3s"
        "${OUTPUT_DIR}/binaries/install.sh"
        "${OUTPUT_DIR}/binaries/kubectl"
        "${OUTPUT_DIR}/binaries/helm"
        "${OUTPUT_DIR}/binaries/crictl"
        "${OUTPUT_DIR}/binaries/cilium"
        "${OUTPUT_DIR}/binaries/etcd"
        "${OUTPUT_DIR}/binaries/etcdctl"
        "${OUTPUT_DIR}/images/k3s-airgap-images-${ARCH}.tar.gz"
        "${OUTPUT_DIR}/helm-charts/cilium-${CILIUM_VERSION}.tgz"
        "${OUTPUT_DIR}/helm-charts/cert-manager-${CERT_MANAGER_VERSION}.tgz"
        "${OUTPUT_DIR}/manifests/cilium-values.yaml"
        "${OUTPUT_DIR}/manifests/k3s-server.env"
        "${OUTPUT_DIR}/manifests/k3s-agent.env"
        "${OUTPUT_DIR}/manifests/load-images.sh"
        "${OUTPUT_DIR}/metadata/version-info.txt"
        "${OUTPUT_DIR}/metadata/architecture.txt"
        "${OUTPUT_DIR}/checksums/sha256sums.txt"
    )

    if [[ "${SKIP_IMAGES}" != "true" ]]; then
        required_files+=(
            "${OUTPUT_DIR}/images/cilium-images.tar"
            "${OUTPUT_DIR}/images/cert-manager-images.tar"
        )
        if [[ "${SKIP_RANCHER}" != "true" ]]; then
            required_files+=(
                "${OUTPUT_DIR}/images/rancher-images.tar"
                "${OUTPUT_DIR}/helm-charts/traefik-${TRAEFIK_CHART_VERSION}.tgz"
                "${OUTPUT_DIR}/helm-charts/rancher-${RANCHER_VERSION}.tgz"
            )
        fi
    fi

    log_info "Checking required files..."
    for path in "${required_files[@]}"; do
        if [[ -f "${path}" ]]; then
            log_ok "${path#${OUTPUT_DIR}/}"
        else
            log_error "MISSING: ${path#${OUTPUT_DIR}/}"
            missing=$((missing + 1))
        fi
    done

    # Binary architecture validation
    log_info "Validating binary architectures..."
    for bin in k3s kubectl helm cilium etcd etcdctl; do
        local bin_path="${OUTPUT_DIR}/binaries/${bin}"
        [[ -f "${bin_path}" ]] || continue

        local file_out
        file_out="$(file "${bin_path}")"

        if [[ "${ARCH}" == "arm64" ]]; then
            if echo "${file_out}" | grep -qiE "arm|aarch64"; then
                log_ok "${bin}: ARM64 ✔"
            else
                log_error "${bin}: expected ARM64, got: ${file_out}"
                arch_errors=$((arch_errors + 1))
            fi
        else
            if echo "${file_out}" | grep -qiE "x86-64|x86_64"; then
                log_ok "${bin}: x86_64 ✔"
            else
                log_error "${bin}: expected x86_64, got: ${file_out}"
                arch_errors=$((arch_errors + 1))
            fi
        fi
    done

    local total=$((missing + arch_errors))
    if [[ "${total}" -gt 0 ]]; then
        log_error "Validation FAILED: ${missing} missing file(s), ${arch_errors} architecture error(s)"
        exit 1
    fi

    log_ok "All validation checks passed"
}

# =============================================================================
# 11. Create Final Compressed Archive
# =============================================================================
create_bundle_archive() {
    log_step "Creating Bundle Archive  → ${BUNDLE_ARCHIVE}"

    local parent_dir
    parent_dir="$(cd "$(dirname "${OUTPUT_DIR}")" && pwd)"
    local bundle_name
    bundle_name="$(basename "${OUTPUT_DIR}")"

    tar -czf "${BUNDLE_ARCHIVE}" \
        -C "${parent_dir}" \
        "${bundle_name}"

    local size
    size="$(du -sh "${BUNDLE_ARCHIVE}" | awk '{print $1}')"
    log_ok "Archive created: ${BUNDLE_ARCHIVE} (${size})"
}

# =============================================================================
# Summary
# =============================================================================
show_summary() {
    local bundle_size
    bundle_size="$(du -sh "${OUTPUT_DIR}" | awk '{print $1}')"
    local archive_size="N/A"
    [[ -f "${BUNDLE_ARCHIVE}" ]] && archive_size="$(du -sh "${BUNDLE_ARCHIVE}" | awk '{print $1}')"

    echo ""
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║        Offline Bundle Preparation Complete        ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    printf "  %-28s %s\n" "Architecture detected:"    "${ARCH}"
    printf "  %-28s %s\n" "Container image archives:"  "${STATS_IMAGES}"
    printf "  %-28s %s\n" "Binaries downloaded:"       "${STATS_BINARIES}"
    printf "  %-28s %s\n" "Ubuntu packages (.deb):"    "${STATS_PACKAGES}"
    printf "  %-28s %s\n" "Helm charts:"               "${STATS_CHARTS}"
    echo ""
    printf "  %-28s %s\n" "Output directory:"          "${OUTPUT_DIR}"
    printf "  %-28s %s\n" "Total bundle size:"         "${bundle_size}"
    printf "  %-28s %s\n" "Compressed archive:"        "${BUNDLE_ARCHIVE} (${archive_size})"
    printf "  %-28s %s\n" "Log file:"                  "${LOG_FILE}"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${NC}"
    echo ""
    echo -e "  ${BOLD}1. Transfer bundle to the air-gapped server:${NC}"
    echo -e "     ${YELLOW}scp ${BUNDLE_ARCHIVE} ubuntu@<target-ip>:/tmp/${NC}"
    echo ""
    echo -e "  ${BOLD}2. On target machine — extract:${NC}"
    echo -e "     ${YELLOW}sudo mkdir -p /opt && sudo tar -xzf /tmp/offline-bundle.tar.gz -C /opt/${NC}"
    echo ""
    echo -e "  ${BOLD}3. Load container images into containerd (on EVERY node):${NC}"
    echo -e "     ${YELLOW}sudo bash /opt/offline-bundle/manifests/load-images.sh${NC}"
    echo ""
    echo -e "  ${BOLD}4. Install K3s Control Plane:${NC}"
    echo -e "     ${YELLOW}export K3S_NODE_IP=\"<control-plane-ip>\"${NC}"
    echo -e "     ${YELLOW}source /opt/offline-bundle/manifests/k3s-server.env${NC}"
    echo -e "     ${YELLOW}sudo -E bash /opt/offline-bundle/binaries/install.sh \\${NC}"
    echo -e "     ${YELLOW}  --flannel-backend=none --disable-kube-proxy \\${NC}"
    echo -e "     ${YELLOW}  --disable-network-policy --disable=traefik --disable=servicelb \\${NC}"
    echo -e "     ${YELLOW}  --cluster-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12 \\${NC}"
    echo -e "     ${YELLOW}  --node-ip=\${K3S_NODE_IP} --tls-san=\${K3S_NODE_IP} \\${NC}"
    echo -e "     ${YELLOW}  --write-kubeconfig-mode=644${NC}"
    echo ""
    echo -e "  ${BOLD}5. Install Cilium (on control plane, after K3s is up):${NC}"
    echo -e "     ${YELLOW}# Edit CHANGE_ME_CONTROL_PLANE_IP in manifests/cilium-values.yaml first${NC}"
    echo -e "     ${YELLOW}sudo /usr/local/bin/helm install cilium \\${NC}"
    echo -e "     ${YELLOW}  /opt/offline-bundle/helm-charts/cilium-${CILIUM_VERSION}.tgz \\${NC}"
    echo -e "     ${YELLOW}  --namespace kube-system \\${NC}"
    echo -e "     ${YELLOW}  -f /opt/offline-bundle/manifests/cilium-values.yaml${NC}"
    echo ""
    echo -e "  ${BOLD}6. Verify checksums (optional, on target):${NC}"
    echo -e "     ${YELLOW}cd /opt/offline-bundle && sha256sum -c checksums/sha256sums.txt${NC}"
    echo ""
    if [[ "${SKIP_RANCHER}" != "true" ]]; then
        echo -e "  ${BOLD}7. (Optional) Install Rancher on a standalone VM:${NC}"
        echo -e "     ${YELLOW}scp offline-bundle.tar.gz ubuntu@<rancher-vm-ip>:/opt/${NC}"
        echo -e "     ${YELLOW}sudo bash scripts/install-rancher.sh \\${NC}"
        echo -e "     ${YELLOW}  --bundle-path /opt/offline-bundle \\${NC}"
        echo -e "     ${YELLOW}  --rancher-ip <rancher-vm-ip> \\${NC}"
        echo -e "     ${YELLOW}  --bootstrap-password changeme${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    # Convert OUTPUT_DIR to absolute path to avoid issues with relative paths in subshells
    if [[ ! "${OUTPUT_DIR}" = /* ]]; then
        OUTPUT_DIR="$(cd . && pwd)/${OUTPUT_DIR}"
    fi

    # Update LOG_DIR based on absolute OUTPUT_DIR
    LOG_DIR="${OUTPUT_DIR}/logs"
    LOG_FILE="${LOG_DIR}/resource-preparation.log"

    # Bootstrap log directory before any logging occurs
    # Create both OUTPUT_DIR and LOG_DIR with proper error handling
    mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}" 2>/dev/null || {
        # Fallback to /tmp if output directory can't be created
        OUTPUT_DIR="/tmp/offline-bundle-$(date +%s)"
        LOG_DIR="${OUTPUT_DIR}/logs"
        LOG_FILE="${LOG_DIR}/resource-preparation.log"
        mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_FILE="/tmp/offline-bundle-$(date +%s).log"
    }

    # Ensure log file can be created and written to
    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}" 2>/dev/null || {
            LOG_FILE="/tmp/offline-bundle-$(date +%s).log"
            touch "${LOG_FILE}"
        }
    fi

    echo -e "${BOLD}${BLUE}"
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │   K3s + Cilium + WireGuard  Offline Bundle Preparer  │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo -e "${NC}"

    log_info "Starting offline bundle preparation"
    log_info "Output directory : ${OUTPUT_DIR}"
    log_info "Bundle archive   : ${BUNDLE_ARCHIVE}"
    log_info "Log file         : ${LOG_FILE}"
    log_info "Skip images      : ${SKIP_IMAGES}"
    log_info "Skip packages    : ${SKIP_PACKAGES}"
    log_info "Skip Rancher     : ${SKIP_RANCHER}"

    check_requirements       # Validate required CLI tools
    create_directories       # Create output folder tree
    detect_architecture      # Detect arch + set binary names

    download_k3s_components  # K3s binary + airgap images + install.sh
    download_binaries        # kubectl, helm, crictl, cilium CLI
    pull_and_save_images     # Docker pull + save cilium, cert-manager images
    download_packages        # Ubuntu .deb packages
    download_helm_charts     # Cilium + cert-manager Helm charts
    create_manifests         # Configuration templates
    write_metadata           # Version + architecture metadata
    generate_checksums       # SHA256 for all artifacts
    validate_bundle          # Verify completeness + binary arch
    create_bundle_archive    # Package everything into offline-bundle.tar.gz
    show_summary             # Print results + next steps

    log_info "Done ✔  Bundle ready: ${BUNDLE_ARCHIVE}"
}

main "$@"
