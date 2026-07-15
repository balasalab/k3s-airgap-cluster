#!/bin/bash

################################################################################
# Strimzi Kafka Operator — Offline Bundle Preparation
#
# Purpose: Download all Kafka artifacts for offline installation on K3s.
#          Run this script on an internet-connected machine, then transfer
#          the generated bundle to your air-gapped environment.
#
# Usage:   ./prepare-kafka-bundle.sh [OPTIONS]
#
# Requires (online machine):
#   - docker (with daemon running)
#   - helm 3.x
#   - curl
#   - python3
#   - Internet connectivity to quay.io and GitHub
#
# Output: kafka-bundle-<version>.tar.gz  (transfer this to the offline cluster)
#
################################################################################
#
# WHY Registry API + pull-by-digest instead of "docker pull --platform"?
#
# Docker's --platform flag is unreliable: if an image tag is already cached
# (even from a previous pull with a different arch), Docker reuses the cache.
#
# Fix — two steps that need no extra packages (only curl + python3 + docker):
#
#   1. Query quay.io Registry V2 API with curl to get the manifest list.
#      Find the digest that corresponds to linux/${TARGET_ARCH}.
#
#   2. Pull by that exact digest: "docker pull repo@sha256:arm64digest"
#      Docker CANNOT use a cached amd64 image because the digest is different.
#      It MUST download the arch-specific layers from the registry.
#
# This guarantees the correct architecture every time, with zero extra packages.
#
################################################################################

set -euo pipefail

# =============================================================================
# Versions  (overridable via environment variables)
# =============================================================================

STRIMZI_VERSION="${STRIMZI_VERSION:-0.48.0}"
KAFKA_VERSION="${KAFKA_VERSION:-4.0.0}"
HELM_BIN="${HELM_BIN:-helm}"

# =============================================================================
# Configuration & Defaults
# =============================================================================

OUTPUT_DIR="${OUTPUT_DIR:-./kafka-bundle-prep}"
BUNDLE_ARCHIVE=""   # set after OUTPUT_DIR is finalised in parse_args

MAX_RETRIES=3
RETRY_DELAY=5
SKIP_IMAGES="${SKIP_IMAGES:-false}"
ARCH_EXPLICIT=""

LOG_DIR="/tmp/kafka-bundle-prep"
LOG_FILE="${LOG_DIR}/prepare.log"

# Auto-detect target architecture from the current machine if not explicitly set.
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
TARGET_ARCH="${TARGET_ARCH:-$(_detect_arch)}"

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
# Retry helper
# =============================================================================

# retry <max> <delay> <cmd> [args...]
# Runs <cmd> up to <max> times, sleeping <delay> seconds between attempts.
retry() {
    local max="$1" delay="$2"
    shift 2
    local attempt=1
    until "$@"; do
        if (( attempt >= max )); then
            log_error "Command failed after ${max} attempt(s): $*"
            return 1
        fi
        log_warn "Attempt ${attempt}/${max} failed. Retrying in ${delay}s..."
        sleep "${delay}"
        (( attempt++ ))
    done
}

# =============================================================================
# Initialization
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}/images" "${OUTPUT_DIR}/charts"

    box "Strimzi Kafka Operator — Offline Bundle Preparation"

    log_info "Output directory: ${OUTPUT_DIR}"
    log_info "Strimzi version:  ${STRIMZI_VERSION}"
    log_info "Kafka version:    ${KAFKA_VERSION}"
    log_info "Target arch:      linux/${TARGET_ARCH}  (host: $(uname -m)${ARCH_EXPLICIT:+, explicitly set})"
    log_info "Skip images:      ${SKIP_IMAGES}"
}

# =============================================================================
# Prerequisite Checks
# =============================================================================

validate_tools() {
    log_step "Validating Required Tools"

    local required_tools=("docker" "helm" "curl" "python3")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            local version
            case "$tool" in
                helm)    version=$(helm version --short 2>&1 | head -1) ;;
                python3) version=$(python3 --version 2>&1 | head -1) ;;
                *)       version=$("$tool" --version 2>&1 | head -1) ;;
            esac
            log_ok "$tool: $version"
        else
            log_error "$tool not found. Please install it before running this script."
            exit 1
        fi
    done

    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running. Start Docker and retry."
        exit 1
    fi
    log_ok "Docker daemon: running"
}

# =============================================================================
# quay.io Registry V2 API — arch-safe image digest lookup
# =============================================================================
#
# quay.io uses the same OCI Distribution Spec as Docker Hub, but with its own
# auth endpoint: https://quay.io/v2/auth (not auth.docker.io).
#
# Flow:
#   1. GET https://quay.io/v2/auth?service=quay.io&scope=repository:<repo>:pull
#      → anonymous bearer token (no credentials needed for public images)
#   2. GET https://quay.io/v2/<repo>/manifests/<tag>
#      with Accept: manifest-list headers
#      → OCI image index JSON listing arch-specific digests
#   3. Extract the digest for linux/${TARGET_ARCH}
#
# Returns the sha256 digest via stdout. Diagnostic output goes to stderr.

get_quay_digest() {
    local image="$1"   # e.g. quay.io/strimzi/operator:0.45.0
    local repo tag full_repo

    # Strip the registry prefix (quay.io/) to get the path and tag
    full_repo="${image#quay.io/}"              # strimzi/operator:0.45.0
    repo="${full_repo%:*}"                     # strimzi/operator
    tag="${full_repo##*:}"                     # 0.45.0

    # Step 1 — Get anonymous bearer token from quay.io
    local token_json token
    token_json=$(curl -fsSL \
        "https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull" \
        2>/dev/null) || {
        echo -e "${RED}  ✘ ERROR: curl failed fetching auth token for ${image}${NC}" >&2
        echo -e "${RED}           Check network connectivity to quay.io${NC}" >&2
        return 1
    }

    token=$(echo "${token_json}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token', d.get('access_token','')))" \
        2>/dev/null) || {
        echo -e "${RED}  ✘ ERROR: Failed to parse auth token for ${image}${NC}" >&2
        return 1
    }

    # Step 2 — Fetch manifest list
    local header_file body_file
    header_file=$(mktemp)
    body_file=$(mktemp)

    curl -fsSL \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, */*" \
        -D "${header_file}" \
        -o "${body_file}" \
        "https://quay.io/v2/${repo}/manifests/${tag}" \
        2>/dev/null || {
        rm -f "${header_file}" "${body_file}"
        echo -e "${RED}  ✘ ERROR: curl failed fetching manifest for ${image}${NC}" >&2
        return 1
    }

    local manifest_json
    manifest_json=$(cat "${body_file}")

    # Read Docker-Content-Digest header (fallback to sha256 of body)
    local content_digest
    content_digest=$(grep -i 'docker-content-digest:' "${header_file}" \
        | awk '{print $2}' | tr -d '\r\n')

    if [[ -z "${content_digest}" ]]; then
        content_digest="sha256:$(sha256sum "${body_file}" | awk '{print $1}')"
    fi

    rm -f "${header_file}" "${body_file}"

    # Step 3 — Extract arch-specific digest from manifest list (OCI index or Docker manifest list)
    local arch_digest=""
    arch_digest=$(echo "${manifest_json}" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
manifests = data.get('manifests', [])
for m in manifests:
    p = m.get('platform', {})
    if p.get('architecture') == '${TARGET_ARCH}' and p.get('os') == 'linux':
        print(m['digest'])
        break
" 2>/dev/null) || true

    if [[ -n "${arch_digest}" ]]; then
        echo -e "${GREEN}    ✔ Found linux/${TARGET_ARCH} digest in manifest index${NC}" >&2
        echo "${arch_digest}"
        return 0
    fi

    # Fallback: single-arch manifest returned (quay.io resolved this tag for the current platform)
    echo -e "${YELLOW}  ⚠ Single-arch manifest returned — using content digest${NC}" >&2
    echo -e "${YELLOW}    Digest: ${content_digest}${NC}" >&2
    echo "${content_digest}"
    return 0
}

# =============================================================================
# Pull Images
# =============================================================================

pull_and_save_images() {
    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log_info "Skipping image pull (--skip-images set)"
        if [[ ! -f "${OUTPUT_DIR}/images/strimzi-operator-${STRIMZI_VERSION}.tar" ]] && \
           [[ ! -f "${OUTPUT_DIR}/images/strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar" ]]; then
            log_warn "Image tar files not found in ${OUTPUT_DIR}/images/ — bundle may be incomplete"
        fi
        return
    fi

    log_step "Pulling Strimzi Images (linux/${TARGET_ARCH})"

    local strimzi_operator_image="quay.io/strimzi/operator:${STRIMZI_VERSION}"
    local strimzi_kafka_image="quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}"

    # ---- strimzi/operator ----
    log_info "Fetching linux/${TARGET_ARCH} digest for: ${strimzi_operator_image}"
    local operator_digest
    operator_digest=$(retry "${MAX_RETRIES}" "${RETRY_DELAY}" get_quay_digest "${strimzi_operator_image}") || exit 1
    log_info "Digest: ${operator_digest}"

    local operator_repo="quay.io/strimzi/operator"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker pull "${operator_repo}@${operator_digest}" 2>&1 | tee -a "${LOG_FILE}"
    docker tag "${operator_repo}@${operator_digest}" "${strimzi_operator_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Pulled & tagged: ${strimzi_operator_image}  (linux/${TARGET_ARCH})"

    log_info "Saving: ${OUTPUT_DIR}/images/strimzi-operator-${STRIMZI_VERSION}.tar"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker save -o \
        "${OUTPUT_DIR}/images/strimzi-operator-${STRIMZI_VERSION}.tar" \
        "${strimzi_operator_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Saved: strimzi-operator-${STRIMZI_VERSION}.tar"

    # ---- strimzi/kafka ----
    log_info "Fetching linux/${TARGET_ARCH} digest for: ${strimzi_kafka_image}"
    local kafka_digest
    kafka_digest=$(retry "${MAX_RETRIES}" "${RETRY_DELAY}" get_quay_digest "${strimzi_kafka_image}") || exit 1
    log_info "Digest: ${kafka_digest}"

    local kafka_repo="quay.io/strimzi/kafka"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker pull "${kafka_repo}@${kafka_digest}" 2>&1 | tee -a "${LOG_FILE}"
    docker tag "${kafka_repo}@${kafka_digest}" "${strimzi_kafka_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Pulled & tagged: ${strimzi_kafka_image}  (linux/${TARGET_ARCH})"

    log_info "Saving: ${OUTPUT_DIR}/images/strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker save -o \
        "${OUTPUT_DIR}/images/strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar" \
        "${strimzi_kafka_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Saved: strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar"

    OPERATOR_DIGEST="${operator_digest}"
    KAFKA_DIGEST="${kafka_digest}"
}

# =============================================================================
# Download Strimzi Helm Chart
# =============================================================================

download_helm_chart() {
    log_step "Downloading Strimzi Helm Chart"

    if ! $HELM_BIN repo list 2>/dev/null | grep -q "strimzi"; then
        retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
            $HELM_BIN repo add strimzi https://strimzi.io/charts/ 2>&1 | tee -a "${LOG_FILE}"
        log_ok "Strimzi Helm repository added"
    else
        log_info "Strimzi Helm repository already present"
    fi

    retry "${MAX_RETRIES}" "${RETRY_DELAY}" \
        $HELM_BIN repo update strimzi 2>&1 | tee -a "${LOG_FILE}"

    $HELM_BIN pull strimzi/strimzi-kafka-operator \
        --version "${STRIMZI_VERSION}" \
        --destination "${OUTPUT_DIR}/charts" \
        2>&1 | tee -a "${LOG_FILE}"

    # Discover the actual filename: Strimzi's chart internal name is
    # strimzi-kafka-operator-helm-3-chart, not strimzi-kafka-operator,
    # so the downloaded .tgz does not match the repo alias name.
    local chart_file
    chart_file=$(find "${OUTPUT_DIR}/charts" -maxdepth 1 -name "strimzi-kafka-operator-*.tgz" | head -1)
    if [[ -n "${chart_file}" ]]; then
        STRIMZI_CHART_FILENAME=$(basename "${chart_file}")
        log_ok "Downloaded: ${STRIMZI_CHART_FILENAME}"
    else
        log_error "Helm chart not found after pull in ${OUTPUT_DIR}/charts/"
        log_error "Directory listing:"
        ls -la "${OUTPUT_DIR}/charts/" 2>&1 | tee -a "${LOG_FILE}" || true
        exit 1
    fi
}

# =============================================================================
# Write MANIFEST.env
# =============================================================================

write_manifest() {
    log_step "Writing MANIFEST.env"

    cat > "${OUTPUT_DIR}/MANIFEST.env" << EOF
# Strimzi Kafka Offline Bundle — MANIFEST.env
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Source this file in bash: source MANIFEST.env

STRIMZI_VERSION="${STRIMZI_VERSION}"
KAFKA_VERSION="${KAFKA_VERSION}"
ARCH="${TARGET_ARCH}"
BUNDLE_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

STRIMZI_OPERATOR_IMAGE="quay.io/strimzi/operator:${STRIMZI_VERSION}"
STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}"
STRIMZI_OPERATOR_TAR="strimzi-operator-${STRIMZI_VERSION}.tar"
STRIMZI_KAFKA_TAR="strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar"
STRIMZI_CHART="${STRIMZI_CHART_FILENAME:-strimzi-kafka-operator-${STRIMZI_VERSION}.tgz}"
OPERATOR_DIGEST="${OPERATOR_DIGEST:-unknown}"
KAFKA_DIGEST="${KAFKA_DIGEST:-unknown}"
EOF

    log_ok "MANIFEST.env written"
}

# =============================================================================
# Pack Bundle
# =============================================================================

pack_bundle() {
    log_step "Creating Bundle Archive"

    BUNDLE_ARCHIVE="${BUNDLE_ARCHIVE:-./kafka-bundle-${STRIMZI_VERSION}.tar.gz}"

    log_info "Packing into: ${BUNDLE_ARCHIVE}"
    tar -czf "${BUNDLE_ARCHIVE}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")" \
        2>&1 | tee -a "${LOG_FILE}"

    local size
    size=$(du -sh "${BUNDLE_ARCHIVE}" | cut -f1)
    log_ok "Bundle created: ${BUNDLE_ARCHIVE} (${size})"
}

# =============================================================================
# Summary
# =============================================================================

summary() {
    log_step "Bundle Preparation Complete"
    echo ""
    box "Strimzi Kafka Bundle Ready!"
    echo ""
    log_ok "Archive:       ${BUNDLE_ARCHIVE}"
    log_ok "Architecture:  linux/${TARGET_ARCH}"
    log_ok "Strimzi:       ${STRIMZI_VERSION}"
    log_ok "Kafka:         ${KAFKA_VERSION}"
    echo ""
    echo "  Contents:"
    echo "    images/strimzi-operator-${STRIMZI_VERSION}.tar"
    echo "    images/strimzi-kafka-${STRIMZI_VERSION}-${KAFKA_VERSION}.tar"
    echo "    charts/${STRIMZI_CHART_FILENAME:-strimzi-kafka-operator-${STRIMZI_VERSION}.tgz}"
    echo "    MANIFEST.env"
    echo ""
    echo "  Next steps:"
    echo "    1. Transfer ${BUNDLE_ARCHIVE} to the offline environment"
    echo "    2. Extract:  tar -xzf kafka-bundle-${STRIMZI_VERSION}.tar.gz -C /opt/"
    echo "    3. Install:  sudo ./kafka_setup/scripts/install-kafka.sh --bundle-path /opt/$(basename "${OUTPUT_DIR}")"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch)
                TARGET_ARCH="$2"
                ARCH_EXPLICIT=1
                if [[ "${TARGET_ARCH}" != "arm64" && "${TARGET_ARCH}" != "amd64" ]]; then
                    echo -e "${RED}  ✘ ERROR: Invalid arch: ${TARGET_ARCH}. Use arm64 or amd64.${NC}"
                    exit 1
                fi
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --skip-images)
                SKIP_IMAGES="true"
                shift
                ;;
            -h|--help)
                cat << 'HELP'
Usage: ./prepare-kafka-bundle.sh [OPTIONS]

Options:
  --arch    arm64|amd64    Target cluster architecture
                           (default: auto-detected from 'uname -m')
  --output-dir PATH        Working directory for downloaded artifacts
                           (default: ./kafka-bundle-prep)
  --skip-images            Skip image pull/save (for re-runs)
  -h, --help               Show this help message

Architecture auto-detection:
  uname -m = aarch64 → arm64 (e.g. Apple Silicon, Raspberry Pi)
  uname -m = x86_64  → amd64 (e.g. Intel/AMD servers)

Examples:
  ./prepare-kafka-bundle.sh                       # auto-detect arch
  ./prepare-kafka-bundle.sh --arch arm64          # force arm64
  ./prepare-kafka-bundle.sh --arch amd64          # force amd64
  ./prepare-kafka-bundle.sh --skip-images         # skip image download
  STRIMZI_VERSION=0.44.0 ./prepare-kafka-bundle.sh  # custom version

Environment overrides:
  STRIMZI_VERSION   Strimzi operator version  (default: 0.45.0)
  KAFKA_VERSION     Kafka version             (default: 3.9.0)
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
    ARCH_EXPLICIT=""
    OPERATOR_DIGEST="unknown"
    KAFKA_DIGEST="unknown"
    STRIMZI_CHART_FILENAME=""

    parse_args "$@"

    # Set bundle archive path now that OUTPUT_DIR is finalised
    BUNDLE_ARCHIVE="./kafka-bundle-${STRIMZI_VERSION}.tar.gz"

    init
    validate_tools
    pull_and_save_images
    download_helm_chart
    write_manifest
    pack_bundle
    summary

    log_info "Bundle preparation finished successfully"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
