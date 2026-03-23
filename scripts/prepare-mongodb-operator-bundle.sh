#!/bin/bash

################################################################################
# Percona MongoDB Operator — Offline Bundle Preparation
#
# Purpose: Download all MongoDB operator artifacts for offline installation
#
# Usage:   ./prepare-mongodb-operator-bundle.sh [OPTIONS]
#
# Requires:
#   - Docker/containerd
#   - Helm 3.x
#   - curl
#   - Internet connectivity
#
# Output: offline-bundle/mongodb-operator/ directory with all artifacts
#
################################################################################
#
# WHY Registry API + pull-by-digest instead of "docker pull --platform"?
#
# Docker's --platform flag is unreliable: if an image tag is already cached
# (even from a previous pull with a different arch), Docker reuses the cache.
# The Docker daemon may also report a different native platform than the OS.
#
# Fix — two steps that need no extra packages (only curl + python3 + docker):
#
#   1. Query the Docker Registry V2 API with curl to get the manifest list.
#      Find the digest that corresponds to linux/${TARGET_ARCH}.
#
#   2. Pull by that exact digest: "docker pull repo@sha256:arm64digest"
#      Docker CANNOT use a cached amd64 image because the digest is different.
#      It MUST download the arm64-specific layers from the registry.
#
# This guarantees the correct architecture every time, with zero extra packages.
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

OUTPUT_DIR="${OUTPUT_DIR:-.}/offline-bundle/mongodb-operator"
MONGODB_OPERATOR_VERSION="1.22.0"       # 1.16.0+ = ARM64 supported; 1.22.0 = latest (Feb 2026)
PERCONA_MONGODB_VERSION="7.0.30-16"     # compatible with operator 1.22.0; ARM64 + amd64
PERCONA_MONGODB_60_VERSION="6.0.27-21"  # compatible with operator 1.22.0; ARM64 + amd64
BACKUP_MONGODB_VERSION="2.13.0"         # compatible with operator 1.22.0; ARM64 + amd64
HELM_BIN="${HELM_BIN:-helm}"
# Auto-detect target architecture from the current machine if not explicitly set.
# Maps uname -m output → Docker/OCI arch names:
#   aarch64 / arm64  → arm64
#   x86_64           → amd64
_detect_arch() {
    local machine
    machine=$(uname -m)
    case "${machine}" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)
            echo "arm64"   # safe default; user can override with --arch
            ;;
    esac
}
TARGET_ARCH="${TARGET_ARCH:-$(_detect_arch)}"   # auto-detected; override with --arch

LOG_DIR="/tmp/mongodb-bundle-prep"
LOG_FILE="${LOG_DIR}/prepare.log"

# Color codes
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
    echo -e "${BLUE}══ [STEP] $*${NC}" | tee -a "${LOG_FILE}"
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
    mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"

    box "Percona MongoDB Operator — Offline Bundle Preparation"

    log_info "Output directory: ${OUTPUT_DIR}"
    log_info "MongoDB Operator: ${MONGODB_OPERATOR_VERSION}"
    log_info "Percona MongoDB: ${PERCONA_MONGODB_VERSION}"
    log_info "Target Arch:     linux/${TARGET_ARCH}  (host: $(uname -m)${ARCH_EXPLICIT:+, explicitly set})"

    log_info "ARM64 Support:   ✅ All images support linux/arm64 (operator 1.16.0+, MongoDB 6.0.27+/7.0.30+)"
}

# =============================================================================
# Validation
# =============================================================================

validate_tools() {
    log_step "Validating Required Tools"

    local required_tools=("docker" "helm" "curl" "python3")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            if [[ "$tool" == "helm" ]]; then
                local version=$(helm version --short 2>&1 | head -1)
            elif [[ "$tool" == "python3" ]]; then
                local version=$(python3 --version 2>&1 | head -1)
            else
                local version=$($tool --version 2>&1 | head -1)
            fi
            log_ok "$tool: $version"
        else
            log_error "$tool not found. Please install it."
            exit 1
        fi
    done

    # Verify Docker daemon is running
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running. Start Docker and retry."
        exit 1
    fi
    log_ok "Docker daemon: running"
}

# =============================================================================
# Add Helm Repositories
# =============================================================================

add_helm_repos() {
    log_step "Adding Percona Helm Repository"

    if ! $HELM_BIN repo list | grep -q "percona"; then
        $HELM_BIN repo add percona https://percona.github.io/percona-helm-charts/
        log_ok "Percona repository added"
    else
        log_info "Percona repository already added"
    fi

    $HELM_BIN repo update 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Helm repositories updated"
}

# =============================================================================
# Download Helm Chart
# =============================================================================

download_helm_charts() {
    log_step "Downloading Percona MongoDB Operator Helm Chart"

    mkdir -p "${OUTPUT_DIR}/helm-charts"

    $HELM_BIN pull percona/psmdb-operator \
        --version "${MONGODB_OPERATOR_VERSION}" \
        --destination "${OUTPUT_DIR}/helm-charts" \
        2>&1 | tee -a "${LOG_FILE}"

    if [[ -f "${OUTPUT_DIR}/helm-charts/psmdb-operator-${MONGODB_OPERATOR_VERSION}.tgz" ]]; then
        log_ok "Downloaded: psmdb-operator-${MONGODB_OPERATOR_VERSION}.tgz"
    else
        log_error "Failed to download Helm chart"
        exit 1
    fi
}

# =============================================================================
# Pull Images via Registry API + pull-by-digest (arch-guaranteed, no extra tools)
# =============================================================================

# Queries Docker Hub Registry V2 API to resolve the linux/${TARGET_ARCH} digest
# for a given image reference (e.g. "percona/percona-server-mongodb:7.0.5-3").
# Prints the sha256 digest on success; exits non-zero on failure.
get_arch_digest() {
    local image="$1"
    local repo tag
    repo=$(echo "$image" | cut -d: -f1)
    tag=$(echo "$image"  | cut -d: -f2)

    # NOTE: This function is called inside $(...) so ALL stdout is captured by the caller.
    # All diagnostic/error output MUST go to stderr (>&2) to remain visible on the terminal.

    # Step 1 — Obtain a Bearer token scoped to this repository
    local token_json
    token_json=$(curl -fsSL \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        2>/dev/null) || {
        echo -e "${RED}  ✘ ERROR: curl failed fetching auth token for ${image}${NC}" >&2
        echo -e "${RED}           Check network connectivity to auth.docker.io${NC}" >&2
        return 1
    }

    local token
    token=$(echo "${token_json}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null) || {
        echo -e "${RED}  ✘ ERROR: Failed to parse auth token for ${image}${NC}" >&2
        echo -e "${RED}           Response was: ${token_json}${NC}" >&2
        return 1
    }

    # Step 2 — Fetch the manifest; save exact bytes to a temp file.
    #
    # Docker Hub may return either:
    #   a) A manifest LIST  (multi-arch) → extract the arch-specific digest from the JSON
    #   b) A single-arch manifest        → Docker Hub did platform-resolution for this machine;
    #                                      digest = Docker-Content-Digest header (if present)
    #                                             OR sha256 of the raw response bytes (fallback)
    #
    # We write the body to a temp file (-o) and headers to another (-D) so we can:
    #   1. Parse the body as JSON
    #   2. Read the Docker-Content-Digest response header
    #   3. Compute sha256 of the exact bytes if the header is absent (sha256 of raw body = content digest)
    local header_file body_file
    header_file=$(mktemp)
    body_file=$(mktemp)

    curl -fsSL \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, */*" \
        -D "${header_file}" \
        -o "${body_file}" \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
        2>/dev/null || {
        rm -f "${header_file}" "${body_file}"
        echo -e "${RED}  ✘ ERROR: curl failed fetching manifest for ${image}${NC}" >&2
        return 1
    }

    local manifest_json
    manifest_json=$(cat "${body_file}")

    # Try Docker-Content-Digest header first (most reliable)
    local content_digest
    content_digest=$(grep -i 'docker-content-digest:' "${header_file}" \
        | awk '{print $2}' | tr -d '\r\n')

    # Fallback: sha256 of the raw response bytes — by definition equals Docker-Content-Digest
    # Docker Hub does not always include this header (behaviour varies by image/version).
    if [[ -z "${content_digest}" ]]; then
        content_digest="sha256:$(sha256sum "${body_file}" | awk '{print $1}')"
    fi

    rm -f "${header_file}" "${body_file}"

    local arch_digest=""

    # Strategy A: manifest list — extract the arch-specific digest from the JSON manifests[] array
    arch_digest=$(echo "${manifest_json}" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('manifests', []):
    p = m.get('platform', {})
    if p.get('architecture') == '${TARGET_ARCH}' and p.get('os') == 'linux':
        print(m['digest'])
        break
" 2>/dev/null) || true

    if [[ -n "${arch_digest}" ]]; then
        echo -e "${GREEN}    ✔ Found linux/${TARGET_ARCH} digest in manifest list${NC}" >&2
        echo "${arch_digest}"
        return 0
    fi

    # Strategy B: single-arch manifest (Docker Hub platform-resolved for this machine).
    # Use the content digest (from header or computed from body sha256).
    echo -e "${YELLOW}  ⚠ Single-arch manifest returned (Docker Hub platform resolved).${NC}" >&2
    echo -e "${YELLOW}    Digest: ${content_digest}${NC}" >&2
    echo "${content_digest}"
    return 0
}

pull_and_save_images() {
    log_step "Pulling Docker Images"

    mkdir -p "${OUTPUT_DIR}/images"

    local images=(
        "percona/percona-server-mongodb-operator:${MONGODB_OPERATOR_VERSION}"
        "percona/percona-server-mongodb:${PERCONA_MONGODB_60_VERSION}"
        "percona/percona-server-mongodb:${PERCONA_MONGODB_VERSION}"
        "percona/percona-backup-mongodb:${BACKUP_MONGODB_VERSION}"
    )

    log_info "Pulling ${#images[@]} images for linux/${TARGET_ARCH} (this may take 10-15 minutes)..."
    log_info "Method: Docker Registry V2 API digest → pull by digest (bypasses Docker cache)"

    local pulled_images=()

    for image in "${images[@]}"; do
        local repo
        repo=$(echo "$image" | cut -d: -f1)

        log_info "  Fetching linux/${TARGET_ARCH} digest for: ${image}"

        local arch_digest
        arch_digest=$(get_arch_digest "${image}") || exit 1

        log_info "  Digest (linux/${TARGET_ARCH}): ${arch_digest}"
        log_info "  Pulling: ${repo}@${arch_digest}"

        # Pull by exact digest — Docker CANNOT reuse a cached tag for a different digest
        if docker pull "${repo}@${arch_digest}" 2>&1 | tee -a "${LOG_FILE}"; then
            # Tag with the original name:tag so k3s / containerd recognises it
            docker tag "${repo}@${arch_digest}" "${image}" 2>&1 | tee -a "${LOG_FILE}"
            log_ok "Pulled & tagged: ${image}  (linux/${TARGET_ARCH})"
            pulled_images+=("${image}")
        else
            log_error "Failed to pull: ${repo}@${arch_digest}"
            exit 1
        fi
    done

    # Pack all images into one combined gzip-compressed tarball
    log_step "Creating Container Image Tarball"
    log_info "Creating tarball for linux/${TARGET_ARCH} (this may take 5 minutes)..."

    local dest_tar="${OUTPUT_DIR}/images/mongodb-operator-images.tar.gz"
    if docker save "${pulled_images[@]}" | gzip > "${dest_tar}"; then
        local size
        size=$(du -sh "${dest_tar}" | cut -f1)
        log_ok "Image tarball created: ${size} (linux/${TARGET_ARCH}, gzip-compressed)"
    else
        log_error "Failed to create image tarball"
        exit 1
    fi
}

# =============================================================================
# Generate Manifest
# =============================================================================

generate_manifest() {
    log_step "Generating Bundle Manifest"

    cat > "${OUTPUT_DIR}/MANIFEST.txt" << EOF
Percona MongoDB Operator — Offline Bundle
==========================================
Generated: $(date)
Target Architecture: linux/${TARGET_ARCH}

Pull Method: Docker Registry V2 API + pull-by-digest (curl + python3 + docker, no extra packages)

Contents:
1. helm-charts/psmdb-operator-${MONGODB_OPERATOR_VERSION}.tgz   — Operator Helm chart
2. images/mongodb-operator-images.tar.gz                         — All images in one gzip-compressed docker-save tarball

Installation Steps (Offline Environment):
1. Transfer this directory to offline environment
2. Run install-mongodb-operator.sh on your K3s control plane
   OR install via Rancher UI (see MONGODB_OPERATOR_OFFLINE_DEPLOYMENT.md)
3. Create MongoDB cluster via Rancher UI or kubectl

Container Images Included (linux/${TARGET_ARCH}):
- percona/percona-server-mongodb-operator:${MONGODB_OPERATOR_VERSION}   (operator)
- percona/percona-server-mongodb:${PERCONA_MONGODB_60_VERSION}           (MongoDB 6.0)
- percona/percona-server-mongodb:${PERCONA_MONGODB_VERSION}              (MongoDB 7.0)
- perconalab/percona-backup-mongodb:${BACKUP_MONGODB_VERSION}            (backup tool)

Operator Features:
- Replica set management with automatic failover
- Backup and restore capabilities
- Monitoring and alerting integration
- Multi-version MongoDB support
- Resource management and autoscaling

Requirements (Offline Environment):
- K3s cluster with containerd runtime (${TARGET_ARCH})
- 2+ CPU cores per MongoDB pod
- 1+ GB RAM per MongoDB pod
- 10+ GB persistent storage

For more info: https://docs.percona.com/percona-server-mongodb-operator/
EOF

    log_ok "Manifest created"
}

# =============================================================================
# Generate Checksums
# =============================================================================

generate_checksums() {
    log_step "Generating SHA256 Checksums"

    cd "${OUTPUT_DIR}"

    (
        find helm-charts -type f -name "*.tgz"
        find images -type f -name "*.tar.gz"
    ) | while read file; do
        sha256sum "$file" >> CHECKSUMS.txt
    done

    log_ok "Checksums generated"
    cd - > /dev/null
}

# =============================================================================
# Summary
# =============================================================================

summary() {
    log_step "Bundle Preparation Complete"

    echo ""
    box "MongoDB Operator Bundle Ready!"
    echo ""

    log_ok "Location:      ${OUTPUT_DIR}"
    log_ok "Architecture:  linux/${TARGET_ARCH}"
    log_ok "Bundle size:   $(du -sh "${OUTPUT_DIR}" | cut -f1)"

    echo ""
    echo "  Files:"
    ls -lh "${OUTPUT_DIR}"/helm-charts/ | tail -1
    ls -lh "${OUTPUT_DIR}"/images/

    echo ""
    echo "  Next step:"
    echo "    1. Transfer bundle to offline environment"
    echo "    2. Run: sudo ./scripts/install-mongodb-operator.sh --bundle-path ${OUTPUT_DIR}"

    echo ""
}

# =============================================================================
# Main
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)
                TARGET_ARCH="$2"
                ARCH_EXPLICIT=1
                if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "amd64" ]]; then
                    log_error "Invalid arch: ${TARGET_ARCH}. Use arm64 or amd64."
                    exit 1
                fi
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: ./prepare-mongodb-operator-bundle.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --arch    arm64|amd64    Target cluster architecture"
                echo "                           (default: auto-detected from 'uname -m')"
                echo "  --output-dir PATH        Output directory (default: ./offline-bundle/mongodb-operator)"
                echo "  -h, --help               Show this help message"
                echo ""
                echo "Architecture auto-detection:"
                echo "  uname -m = aarch64 → arm64 (e.g. Apple Silicon, Raspberry Pi)"
                echo "  uname -m = x86_64  → amd64 (e.g. Intel/AMD servers)"
                echo ""
                echo "Examples:"
                echo "  ./prepare-mongodb-operator-bundle.sh                    # auto-detect arch"
                echo "  ./prepare-mongodb-operator-bundle.sh --arch arm64       # force arm64"
                echo "  ./prepare-mongodb-operator-bundle.sh --arch amd64       # force amd64"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1. Use --help for usage."
                exit 1
                ;;
        esac
    done
}

main() {
    ARCH_EXPLICIT=""
    parse_args "$@"
    init
    validate_tools
    add_helm_repos
    download_helm_charts
    pull_and_save_images
    generate_manifest
    generate_checksums
    summary

    log_info "Bundle preparation finished successfully"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
