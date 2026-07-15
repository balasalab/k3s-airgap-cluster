#!/bin/bash

################################################################################
# Strimzi Kafka Operator — Offline Upgrade Bundle Preparation
#
# Purpose: Download DELTA artifacts (new operator + Kafka images + Helm chart)
#          needed to upgrade Strimzi/Kafka on an offline K3s cluster.
#          Run on an internet-connected machine, then transfer the bundle.
#
# Usage:   ./prepare-kafka-upgrade-bundle.sh \
#            --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
#            --from-kafka 4.0.0   --to-kafka 4.1.0
#
# Requires (online machine):
#   - docker (with daemon running)
#   - helm 3.x
#   - curl
#   - python3
#   - Internet connectivity to quay.io
#
# Output: kafka-upgrade-<FROM>-to-<TO>.tar.gz
#         (transfer this to the offline cluster, then run upgrade-kafka.sh)
#
################################################################################
#
# WHY delta bundle instead of full re-download?
#
# The old images are already loaded in K3s containerd from the initial install.
# Only the NEW version images and chart need to be transferred (~500MB vs ~1.1GB).
# UPGRADE-MANIFEST.env stores FROM/TO versions so upgrade-kafka.sh can verify
# the cluster is on the expected version before starting.
#
################################################################################

set -euo pipefail

# =============================================================================
# Versions (required — no defaults; must be provided via flags)
# =============================================================================

FROM_STRIMZI_VERSION=""
TO_STRIMZI_VERSION=""
FROM_KAFKA_VERSION=""
TO_KAFKA_VERSION=""
HELM_BIN="${HELM_BIN:-helm}"

# =============================================================================
# Configuration & Defaults
# =============================================================================

OUTPUT_DIR="${OUTPUT_DIR:-}"   # set in parse_args after versions are known
BUNDLE_ARCHIVE=""              # set in main() after versions are known

MAX_RETRIES=3
RETRY_DELAY=5
SKIP_IMAGES="${SKIP_IMAGES:-false}"
ARCH_EXPLICIT=""

LOG_DIR="/tmp/kafka-upgrade-bundle-prep"
LOG_FILE="${LOG_DIR}/prepare-upgrade.log"

# Populated during download
STRIMZI_CHART_FILENAME=""
OPERATOR_DIGEST="unknown"
KAFKA_DIGEST="unknown"

# =============================================================================
# Architecture detection
# =============================================================================

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

    box "Strimzi Kafka — Offline Upgrade Bundle Preparation"

    log_info "Upgrade:       Strimzi ${FROM_STRIMZI_VERSION} → ${TO_STRIMZI_VERSION}"
    log_info "Kafka:         ${FROM_KAFKA_VERSION} → ${TO_KAFKA_VERSION}"
    log_info "Target arch:   linux/${TARGET_ARCH}  (host: $(uname -m)${ARCH_EXPLICIT:+, explicitly set})"
    log_info "Output dir:    ${OUTPUT_DIR}"
    log_info "Skip images:   ${SKIP_IMAGES}"
    log_info "Log file:      ${LOG_FILE}"
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

get_quay_digest() {
    local image="$1"   # e.g. quay.io/strimzi/operator:0.49.0
    local repo tag full_repo

    full_repo="${image#quay.io/}"
    repo="${full_repo%:*}"
    tag="${full_repo##*:}"

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

    local content_digest
    content_digest=$(grep -i 'docker-content-digest:' "${header_file}" \
        | awk '{print $2}' | tr -d '\r\n')

    if [[ -z "${content_digest}" ]]; then
        content_digest="sha256:$(sha256sum "${body_file}" | awk '{print $1}')"
    fi

    rm -f "${header_file}" "${body_file}"

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

    echo -e "${YELLOW}  ⚠ Single-arch manifest returned — using content digest${NC}" >&2
    echo -e "${YELLOW}    Digest: ${content_digest}${NC}" >&2
    echo "${content_digest}"
    return 0
}

# =============================================================================
# Download new operator image
# =============================================================================

download_operator_image() {
    local new_image="quay.io/strimzi/operator:${TO_STRIMZI_VERSION}"
    local out_tar="${OUTPUT_DIR}/images/new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"

    log_step "Downloading New Strimzi Operator Image"
    log_info "Image: ${new_image}  (linux/${TARGET_ARCH})"

    local operator_digest
    operator_digest=$(retry "${MAX_RETRIES}" "${RETRY_DELAY}" get_quay_digest "${new_image}") || exit 1
    log_info "Digest: ${operator_digest}"

    local repo="quay.io/strimzi/operator"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker pull "${repo}@${operator_digest}" 2>&1 | tee -a "${LOG_FILE}"
    docker tag "${repo}@${operator_digest}" "${new_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Pulled & tagged: ${new_image}  (linux/${TARGET_ARCH})"

    log_info "Saving: ${out_tar}"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker save -o "${out_tar}" "${new_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Saved: new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"

    OPERATOR_DIGEST="${operator_digest}"
}

# =============================================================================
# Download new Kafka image
# =============================================================================

download_kafka_image() {
    local new_image="quay.io/strimzi/kafka:${TO_STRIMZI_VERSION}-kafka-${TO_KAFKA_VERSION}"
    local out_tar="${OUTPUT_DIR}/images/new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"

    log_step "Downloading New Strimzi Kafka Image"
    log_info "Image: ${new_image}  (linux/${TARGET_ARCH})"

    local kafka_digest
    kafka_digest=$(retry "${MAX_RETRIES}" "${RETRY_DELAY}" get_quay_digest "${new_image}") || exit 1
    log_info "Digest: ${kafka_digest}"

    local repo="quay.io/strimzi/kafka"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker pull "${repo}@${kafka_digest}" 2>&1 | tee -a "${LOG_FILE}"
    docker tag "${repo}@${kafka_digest}" "${new_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Pulled & tagged: ${new_image}  (linux/${TARGET_ARCH})"

    log_info "Saving: ${out_tar}"
    retry "${MAX_RETRIES}" "${RETRY_DELAY}" docker save -o "${out_tar}" "${new_image}" 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Saved: new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"

    KAFKA_DIGEST="${kafka_digest}"
}

# =============================================================================
# Download new Helm chart
# =============================================================================

download_helm_chart() {
    log_step "Downloading Strimzi Helm Chart (${TO_STRIMZI_VERSION})"

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
        --version "${TO_STRIMZI_VERSION}" \
        --destination "${OUTPUT_DIR}/charts" \
        2>&1 | tee -a "${LOG_FILE}"

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
# Verify all artifacts
# =============================================================================

verify_artifacts() {
    log_step "Verifying Artifacts"

    local missing=0

    local operator_tar="${OUTPUT_DIR}/images/new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"
    if [[ -f "${operator_tar}" ]] && [[ -s "${operator_tar}" ]]; then
        log_ok "images/new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"
    else
        log_error "Missing or empty: ${operator_tar}"
        missing=1
    fi

    local kafka_tar="${OUTPUT_DIR}/images/new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"
    if [[ -f "${kafka_tar}" ]] && [[ -s "${kafka_tar}" ]]; then
        log_ok "images/new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"
    else
        log_error "Missing or empty: ${kafka_tar}"
        missing=1
    fi

    local chart_file="${OUTPUT_DIR}/charts/${STRIMZI_CHART_FILENAME}"
    if [[ -f "${chart_file}" ]] && [[ -s "${chart_file}" ]]; then
        log_ok "charts/${STRIMZI_CHART_FILENAME}"
    else
        log_error "Missing or empty: ${chart_file}"
        missing=1
    fi

    if [[ "${missing}" -ne 0 ]]; then
        log_error "Artifact verification failed. Bundle not created."
        exit 1
    fi

    log_ok "All artifacts verified"
}

# =============================================================================
# Write UPGRADE-MANIFEST.env
# =============================================================================

write_upgrade_manifest() {
    log_step "Writing UPGRADE-MANIFEST.env"

    cat > "${OUTPUT_DIR}/UPGRADE-MANIFEST.env" << EOF
# Strimzi Kafka Offline Upgrade Bundle — UPGRADE-MANIFEST.env
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Source this file in bash: source UPGRADE-MANIFEST.env

FROM_STRIMZI_VERSION="${FROM_STRIMZI_VERSION}"
TO_STRIMZI_VERSION="${TO_STRIMZI_VERSION}"
FROM_KAFKA_VERSION="${FROM_KAFKA_VERSION}"
TO_KAFKA_VERSION="${TO_KAFKA_VERSION}"
ARCH="${TARGET_ARCH}"
BUNDLE_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

NEW_STRIMZI_OPERATOR_TAR="new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"
NEW_STRIMZI_KAFKA_TAR="new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"
STRIMZI_CHART="${STRIMZI_CHART_FILENAME}"

NEW_STRIMZI_OPERATOR_IMAGE="quay.io/strimzi/operator:${TO_STRIMZI_VERSION}"
NEW_STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:${TO_STRIMZI_VERSION}-kafka-${TO_KAFKA_VERSION}"
OPERATOR_DIGEST="${OPERATOR_DIGEST}"
KAFKA_DIGEST="${KAFKA_DIGEST}"
EOF

    log_ok "UPGRADE-MANIFEST.env written"
}

# =============================================================================
# Package bundle
# =============================================================================

package_bundle() {
    log_step "Creating Upgrade Bundle Archive"

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
    log_step "Upgrade Bundle Preparation Complete"
    echo ""
    box "Kafka Upgrade Bundle Ready!"
    echo ""
    log_ok "Archive:       ${BUNDLE_ARCHIVE}"
    log_ok "Architecture:  linux/${TARGET_ARCH}"
    log_ok "From:          Strimzi ${FROM_STRIMZI_VERSION} / Kafka ${FROM_KAFKA_VERSION}"
    log_ok "To:            Strimzi ${TO_STRIMZI_VERSION} / Kafka ${TO_KAFKA_VERSION}"
    echo ""
    echo "  Bundle contents:"
    echo "    images/new-strimzi-operator-${TO_STRIMZI_VERSION}.tar"
    echo "    images/new-strimzi-kafka-${TO_STRIMZI_VERSION}-${TO_KAFKA_VERSION}.tar"
    echo "    charts/${STRIMZI_CHART_FILENAME}"
    echo "    UPGRADE-MANIFEST.env"
    echo ""
    echo "  Next steps:"
    echo "    1. Transfer ${BUNDLE_ARCHIVE} to the offline cluster"
    local bundle_base
    bundle_base=$(basename "${BUNDLE_ARCHIVE}" .tar.gz)
    echo "    2. Extract:  tar -xzf $(basename "${BUNDLE_ARCHIVE}") -C /opt/"
    echo "    3. Upgrade:  sudo ./kafka_setup/scripts/upgrade-kafka.sh --bundle-path /opt/${bundle_base}"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-strimzi)
                FROM_STRIMZI_VERSION="$2"
                shift 2
                ;;
            --to-strimzi)
                TO_STRIMZI_VERSION="$2"
                shift 2
                ;;
            --from-kafka)
                FROM_KAFKA_VERSION="$2"
                shift 2
                ;;
            --to-kafka)
                TO_KAFKA_VERSION="$2"
                shift 2
                ;;
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
Usage: ./prepare-kafka-upgrade-bundle.sh [OPTIONS]

Required:
  --from-strimzi VERSION   Current Strimzi version on cluster (e.g. 0.48.0)
  --to-strimzi   VERSION   Target Strimzi version            (e.g. 0.49.0)
  --from-kafka   VERSION   Current Kafka version on cluster  (e.g. 4.0.0)
  --to-kafka     VERSION   Target Kafka version              (e.g. 4.1.0)

Optional:
  --arch    arm64|amd64    Target cluster architecture (default: auto-detected)
  --output-dir PATH        Working directory for downloaded artifacts
  --skip-images            Skip image pull/save (for re-runs or chart-only update)
  -h, --help               Show this help message

Examples:
  ./prepare-kafka-upgrade-bundle.sh \
    --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
    --from-kafka 4.0.0 --to-kafka 4.1.0

  ./prepare-kafka-upgrade-bundle.sh \
    --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
    --from-kafka 4.0.0 --to-kafka 4.0.0 \
    --arch amd64          # operator-only upgrade, same Kafka version

  ./prepare-kafka-upgrade-bundle.sh \
    --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
    --from-kafka 4.0.0 --to-kafka 4.1.0 \
    --skip-images         # chart only, images already downloaded
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

    # Validate required flags
    local missing_flags=()
    [[ -z "${FROM_STRIMZI_VERSION}" ]] && missing_flags+=("--from-strimzi")
    [[ -z "${TO_STRIMZI_VERSION}" ]]   && missing_flags+=("--to-strimzi")
    [[ -z "${FROM_KAFKA_VERSION}" ]]   && missing_flags+=("--from-kafka")
    [[ -z "${TO_KAFKA_VERSION}" ]]     && missing_flags+=("--to-kafka")

    if [[ ${#missing_flags[@]} -gt 0 ]]; then
        echo -e "${RED}  ✘ ERROR: Missing required flags: ${missing_flags[*]}${NC}"
        echo "  Run with --help for usage."
        exit 1
    fi

    # Set derived paths now that versions are known
    OUTPUT_DIR="${OUTPUT_DIR:-./kafka-upgrade-${FROM_STRIMZI_VERSION}-to-${TO_STRIMZI_VERSION}}"
    BUNDLE_ARCHIVE="./kafka-upgrade-${FROM_STRIMZI_VERSION}-to-${TO_STRIMZI_VERSION}.tar.gz"

    init
    validate_tools

    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log_info "Skipping image download (--skip-images set)"
    else
        download_operator_image
        download_kafka_image
    fi

    download_helm_chart
    verify_artifacts
    write_upgrade_manifest
    package_bundle
    summary

    log_info "Upgrade bundle preparation finished successfully"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
