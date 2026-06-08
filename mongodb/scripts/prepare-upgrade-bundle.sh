#!/bin/bash

################################################################################
# Percona MongoDB Operator — Offline Upgrade Bundle Preparation
#
# Purpose: Download delta artifacts (changed images + Helm chart) needed to
#          upgrade the Percona MongoDB Operator on an offline K3s cluster.
#
# Usage:   ./prepare-upgrade-bundle.sh \
#            --from-operator  1.21.0 \
#            --to-operator    1.22.0 \
#            --from-mongodb   6.0.7-4 \
#            --to-mongodb     7.0.30-16 \
#            --arch           amd64
#
# Requires:
#   - Docker/containerd
#   - Helm 3.x
#   - curl, python3
#   - Internet connectivity
#
# Output: upgrade-bundle-<VERSION>.tar.gz (or upgrade-bundle-mongodb-<DATE>.tar.gz)
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

OUTPUT_DIR="${OUTPUT_DIR:-.}/offline-bundle/mongodb-upgrade"
HELM_BIN="${HELM_BIN:-helm}"

# Operator versions (scalar — one pair)
FROM_OPERATOR_VERSION=""
TO_OPERATOR_VERSION=""

# MongoDB version pairs (arrays — repeatable via --from-mongodb / --to-mongodb)
FROM_MONGODB_VERSIONS=()
TO_MONGODB_VERSIONS=()

# Backup agent versions (scalar — one pair)
FROM_BACKUP_AGENT_VERSION=""
TO_BACKUP_AGENT_VERSION=""

# Delta include flags (set by compute_delta)
INCLUDE_OPERATOR=false
INCLUDE_BACKUP_AGENT=false
MONGODB_PAIRS=()   # colon-separated "from:to" strings, populated by compute_delta

FULL_MODE=false
ARCH_EXPLICIT=""

_detect_arch() {
    local machine
    machine=$(uname -m)
    case "${machine}" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "arm64" ;;
    esac
}
TARGET_ARCH="${TARGET_ARCH:-$(_detect_arch)}"

LOG_DIR="/tmp/mongodb-upgrade-bundle-prep"
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
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-operator)     FROM_OPERATOR_VERSION="$2";                   shift 2 ;;
            --to-operator)       TO_OPERATOR_VERSION="$2";                     shift 2 ;;
            --from-mongodb)      FROM_MONGODB_VERSIONS+=("$2");                shift 2 ;;
            --to-mongodb)        TO_MONGODB_VERSIONS+=("$2");                  shift 2 ;;
            --from-backup-agent) FROM_BACKUP_AGENT_VERSION="$2";               shift 2 ;;
            --to-backup-agent)   TO_BACKUP_AGENT_VERSION="$2";                 shift 2 ;;
            --arch)
                TARGET_ARCH="$2"
                ARCH_EXPLICIT=1
                if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "amd64" ]]; then
                    log_error "Invalid arch: ${TARGET_ARCH}. Use arm64 or amd64."
                    echo "  → Run with --help for usage"
                    exit 1
                fi
                shift 2
                ;;
            --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
            --full)         FULL_MODE=true;  shift ;;
            -h|--help)
                echo "Usage: ./prepare-upgrade-bundle.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --from-operator VER      Currently installed operator version"
                echo "  --to-operator   VER      Target operator version"
                echo "  --from-mongodb  VER      Currently installed MongoDB image version (repeatable)"
                echo "  --to-mongodb    VER      Target MongoDB image version (repeatable)"
                echo "                           Pairs are matched in order: 1st --from with 1st --to, etc."
                echo "  --from-backup-agent VER  Currently installed backup agent version"
                echo "  --to-backup-agent   VER  Target backup agent version"
                echo "  --arch arm64|amd64       Target arch (default: auto-detected from 'uname -m')"
                echo "                           uname -m = aarch64 → arm64"
                echo "                           uname -m = x86_64  → amd64"
                echo "  --output-dir PATH        Output directory (default: ./offline-bundle/mongodb-upgrade)"
                echo "  --full                   Include all target-version images regardless of delta"
                echo "  -h, --help               Show this help message"
                echo ""
                echo "Examples:"
                echo "  # Operator-only upgrade:"
                echo "  ./prepare-upgrade-bundle.sh --from-operator 1.21.0 --to-operator 1.22.0 --arch arm64"
                echo ""
                echo "  # MongoDB upgrade (any version to any version):"
                echo "  ./prepare-upgrade-bundle.sh \\"
                echo "    --from-mongodb 6.0.7-4 --to-mongodb 7.0.30-16 \\"
                echo "    --arch amd64"
                echo ""
                echo "  # Operator + multiple MongoDB version pairs:"
                echo "  ./prepare-upgrade-bundle.sh \\"
                echo "    --from-operator 1.21.0 --to-operator 1.22.0 \\"
                echo "    --from-mongodb 6.0.7-4   --to-mongodb 7.0.30-16 \\"
                echo "    --from-mongodb 5.0.29-18 --to-mongodb 6.0.27-21 \\"
                echo "    --arch arm64"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "  → Run with --help for usage"
                exit 1
                ;;
        esac
    done

    # Validate: --from-mongodb and --to-mongodb counts must match
    if [[ ${#FROM_MONGODB_VERSIONS[@]} -ne ${#TO_MONGODB_VERSIONS[@]} ]]; then
        log_error "--from-mongodb and --to-mongodb counts do not match"
        log_error "  --from-mongodb provided : ${#FROM_MONGODB_VERSIONS[@]}"
        log_error "  --to-mongodb provided   : ${#TO_MONGODB_VERSIONS[@]}"
        echo "  → Each --from-mongodb must have a corresponding --to-mongodb"
        exit 1
    fi
}

# =============================================================================
# Initialization
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"

    box "Percona MongoDB Operator — Offline Upgrade Bundle Preparation"

    log_info "Configuration:"
    log_info "  Architecture   : linux/${TARGET_ARCH}  (host: $(uname -m)${ARCH_EXPLICIT:+, explicitly set})"
    log_info "  Output Dir     : ${OUTPUT_DIR}"
    log_info "  Full Mode      : ${FULL_MODE}"
    log_info ""
    log_info "  Version Pairs:"
    log_info "    Operator     : ${FROM_OPERATOR_VERSION:-<not set>}  →  ${TO_OPERATOR_VERSION:-<not set>}"

    if [[ ${#FROM_MONGODB_VERSIONS[@]} -gt 0 ]]; then
        for i in "${!FROM_MONGODB_VERSIONS[@]}"; do
            log_info "    MongoDB      : ${FROM_MONGODB_VERSIONS[$i]}  →  ${TO_MONGODB_VERSIONS[$i]}"
        done
    else
        log_info "    MongoDB      : <not set>"
    fi

    log_info "    Backup Agent : ${FROM_BACKUP_AGENT_VERSION:-<not set>}  →  ${TO_BACKUP_AGENT_VERSION:-<not set>}"
}

# =============================================================================
# Tool Validation
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
                *)       version=$($tool --version 2>&1 | head -1) ;;
            esac
            log_ok "$tool: $version"
        else
            log_error "$tool not found. Please install it."
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
# Helm Repository Setup
# =============================================================================

add_helm_repos() {
    log_step "Setting Up Helm Repository"

    if ! $HELM_BIN repo list 2>/dev/null | grep -q "percona"; then
        $HELM_BIN repo add percona https://percona.github.io/percona-helm-charts/
        log_ok "Percona repository added"
    else
        log_info "Percona repository already present"
    fi

    $HELM_BIN repo update 2>&1 | tee -a "${LOG_FILE}"
    log_ok "Helm repositories updated"
}

# =============================================================================
# Delta Computation
# =============================================================================

compute_delta() {
    log_step "Computing Upgrade Delta"

    if [[ "${FULL_MODE}" == "true" ]]; then
        log_info "  --full mode: including all provided version pairs"
        INCLUDE_OPERATOR=true
        INCLUDE_BACKUP_AGENT=true
        # In full mode, include every provided MongoDB pair regardless of whether FROM==TO
        for i in "${!FROM_MONGODB_VERSIONS[@]}"; do
            MONGODB_PAIRS+=("${FROM_MONGODB_VERSIONS[$i]}:${TO_MONGODB_VERSIONS[$i]}")
            log_ok "MongoDB: ${FROM_MONGODB_VERSIONS[$i]} → ${TO_MONGODB_VERSIONS[$i]} (full mode)"
        done
    else
        # Operator
        if [[ -n "${FROM_OPERATOR_VERSION}" && -n "${TO_OPERATOR_VERSION}" ]] \
           && [[ "${FROM_OPERATOR_VERSION}" != "${TO_OPERATOR_VERSION}" ]]; then
            INCLUDE_OPERATOR=true
            log_ok "Operator: ${FROM_OPERATOR_VERSION} → ${TO_OPERATOR_VERSION} (CHANGED)"
        else
            log_info "  Operator: unchanged (${FROM_OPERATOR_VERSION:-not set})"
        fi

        # MongoDB pairs — include only where FROM != TO
        for i in "${!FROM_MONGODB_VERSIONS[@]}"; do
            local from="${FROM_MONGODB_VERSIONS[$i]}"
            local to="${TO_MONGODB_VERSIONS[$i]}"
            if [[ "${from}" != "${to}" ]]; then
                MONGODB_PAIRS+=("${from}:${to}")
                log_ok "MongoDB: ${from} → ${to} (CHANGED)"
            else
                log_info "  MongoDB: unchanged (${from})"
            fi
        done

        # Backup agent
        if [[ -n "${FROM_BACKUP_AGENT_VERSION}" && -n "${TO_BACKUP_AGENT_VERSION}" ]] \
           && [[ "${FROM_BACKUP_AGENT_VERSION}" != "${TO_BACKUP_AGENT_VERSION}" ]]; then
            INCLUDE_BACKUP_AGENT=true
            log_ok "Backup Agent: ${FROM_BACKUP_AGENT_VERSION} → ${TO_BACKUP_AGENT_VERSION} (CHANGED)"
        else
            log_info "  Backup Agent: unchanged (${FROM_BACKUP_AGENT_VERSION:-not set})"
        fi

        # Exit if nothing to upgrade
        if [[ "${INCLUDE_OPERATOR}" == "false" && ${#MONGODB_PAIRS[@]} -eq 0 \
              && "${INCLUDE_BACKUP_AGENT}" == "false" ]]; then
            log_error "No components require upgrading — all FROM/TO version pairs are identical."
            echo "  → Check your --from-X and --to-X arguments, or use --full to force inclusion."
            exit 1
        fi
    fi
}

# =============================================================================
# Download Helm Chart
# =============================================================================

download_helm_chart() {
    if [[ "${INCLUDE_OPERATOR}" != "true" ]]; then
        log_info "Operator not being upgraded — skipping Helm chart download."
        return
    fi

    log_step "Downloading Helm Chart"

    mkdir -p "${OUTPUT_DIR}/helm-charts"

    $HELM_BIN pull percona/psmdb-operator \
        --version "${TO_OPERATOR_VERSION}" \
        --destination "${OUTPUT_DIR}/helm-charts" \
        2>&1 | tee -a "${LOG_FILE}"

    if [[ -f "${OUTPUT_DIR}/helm-charts/psmdb-operator-${TO_OPERATOR_VERSION}.tgz" ]]; then
        log_ok "Downloaded: psmdb-operator-${TO_OPERATOR_VERSION}.tgz"
    else
        log_error "Failed to download Helm chart for operator ${TO_OPERATOR_VERSION}"
        exit 1
    fi
}

# =============================================================================
# Registry V2 API + pull-by-digest
#
# NOTE: This function is duplicated in prepare-mongodb-operator-bundle.sh
#       Apply bug fixes to both files.
# =============================================================================

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

    # Step 2 — Fetch the manifest list
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

    echo -e "${YELLOW}  ⚠ Single-arch manifest returned (Docker Hub platform resolved).${NC}" >&2
    echo -e "${YELLOW}    Digest: ${content_digest}${NC}" >&2
    echo "${content_digest}"
    return 0
}

# =============================================================================
# Pull and Save Images
# =============================================================================

pull_and_save_images() {
    log_step "Pulling Container Images"

    mkdir -p "${OUTPUT_DIR}/images"

    # Build list of images to pull
    local images=()

    if [[ "${INCLUDE_OPERATOR}" == "true" ]]; then
        images+=("percona/percona-server-mongodb-operator:${TO_OPERATOR_VERSION}")
    fi

    # Add the TO side of each MongoDB pair
    for pair in "${MONGODB_PAIRS[@]}"; do
        local to_version="${pair#*:}"
        images+=("percona/percona-server-mongodb:${to_version}")
    done

    if [[ "${INCLUDE_BACKUP_AGENT}" == "true" ]]; then
        images+=("percona/percona-backup-mongodb:${TO_BACKUP_AGENT_VERSION}")
    fi

    if [[ ${#images[@]} -eq 0 ]]; then
        log_info "No images to pull (no image components in delta)."
        return
    fi

    log_info "Pulling ${#images[@]} image(s) for linux/${TARGET_ARCH}..."
    log_info "Method: Docker Registry V2 API + pull-by-digest (bypasses Docker cache)"

    local pulled_images=()

    for image in "${images[@]}"; do
        local repo
        repo=$(echo "$image" | cut -d: -f1)

        log_info "  Fetching linux/${TARGET_ARCH} digest for: ${image}"

        local arch_digest
        arch_digest=$(get_arch_digest "${image}") || exit 1

        log_info "  Digest (linux/${TARGET_ARCH}): ${arch_digest}"
        log_info "  Pulling: ${repo}@${arch_digest}"

        if docker pull "${repo}@${arch_digest}" 2>&1 | tee -a "${LOG_FILE}"; then
            docker tag "${repo}@${arch_digest}" "${image}" 2>&1 | tee -a "${LOG_FILE}"
            log_ok "Pulled & tagged: ${image}  (linux/${TARGET_ARCH})"
            pulled_images+=("${image}")
        else
            log_error "Failed to pull: ${repo}@${arch_digest}"
            exit 1
        fi
    done

    log_step "Creating Image Tarball"
    log_info "Saving ${#pulled_images[@]} image(s) to tarball (may take several minutes)..."

    local dest_tar="${OUTPUT_DIR}/images/mongodb-upgrade-images.tar.gz"
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
# Generate MANIFEST.env
# =============================================================================

generate_manifest() {
    log_step "Generating MANIFEST.env"

    # Build IMAGES_INCLUDED token list
    local images_included=""
    [[ "${INCLUDE_OPERATOR}" == "true" ]]     && images_included+="operator "
    [[ ${#MONGODB_PAIRS[@]} -gt 0 ]]          && images_included+="mongodb "
    [[ "${INCLUDE_BACKUP_AGENT}" == "true" ]] && images_included+="backup-agent "
    images_included="${images_included% }"

    local helm_chart=""
    [[ "${INCLUDE_OPERATOR}" == "true" ]] && helm_chart="psmdb-operator-${TO_OPERATOR_VERSION}.tgz"

    local images_file=""
    [[ -n "${images_included}" ]] && images_file="mongodb-upgrade-images.tar.gz"

    # Build the MongoDB pairs section dynamically
    local pairs_section=""
    pairs_section+="MONGODB_PAIRS_COUNT=${#MONGODB_PAIRS[@]}"$'\n'
    for i in "${!MONGODB_PAIRS[@]}"; do
        local n=$((i + 1))
        local from_ver="${MONGODB_PAIRS[$i]%%:*}"
        local to_ver="${MONGODB_PAIRS[$i]#*:}"
        pairs_section+="MONGODB_PAIR_${n}_FROM=\"${from_ver}\""$'\n'
        pairs_section+="MONGODB_PAIR_${n}_TO=\"${to_ver}\""$'\n'
    done

    cat > "${OUTPUT_DIR}/MANIFEST.env" << EOF
# Percona MongoDB Operator — Offline Upgrade Bundle Manifest
# Generated: $(date)
# Architecture: linux/${TARGET_ARCH}
# Source: prepare-upgrade-bundle.sh

BUNDLE_TYPE=upgrade
BUNDLE_CREATED="$(date)"
ARCH="${TARGET_ARCH}"

# Operator
UPGRADE_OPERATOR=${INCLUDE_OPERATOR}
OPERATOR_FROM_VERSION="${FROM_OPERATOR_VERSION}"
OPERATOR_TO_VERSION="${TO_OPERATOR_VERSION}"

# MongoDB image pairs (any version → any version)
${pairs_section}
# Backup Agent
UPGRADE_BACKUP_AGENT=${INCLUDE_BACKUP_AGENT}
BACKUP_AGENT_FROM_VERSION="${FROM_BACKUP_AGENT_VERSION}"
BACKUP_AGENT_TO_VERSION="${TO_BACKUP_AGENT_VERSION}"

# Bundle contents
IMAGES_FILE="${images_file}"
HELM_CHART="${helm_chart}"
IMAGES_INCLUDED="${images_included}"

# Upgrade order (must not be changed — upgrade script enforces this)
UPDATE_ORDER="images crds operator mongodb"
EOF

    log_ok "MANIFEST.env created"

    # Verify it sources cleanly
    if bash -c "source '${OUTPUT_DIR}/MANIFEST.env'" 2>/dev/null; then
        log_ok "MANIFEST.env verified: sources cleanly"
    else
        log_error "MANIFEST.env failed syntax check"
        exit 1
    fi
}

# =============================================================================
# Generate Checksums
# =============================================================================

generate_checksums() {
    log_step "Generating SHA256 Checksums"

    cd "${OUTPUT_DIR}"

    rm -f CHECKSUMS.txt

    (
        find helm-charts -type f -name "*.tgz" 2>/dev/null || true
        find images -type f -name "*.tar.gz" 2>/dev/null || true
    ) | while read -r file; do
        sha256sum "$file" >> CHECKSUMS.txt
    done

    if [[ -f CHECKSUMS.txt ]]; then
        log_ok "Checksums generated:"
        cat CHECKSUMS.txt | while read -r line; do log_info "  ${line}"; done
    else
        log_info "No artifacts to checksum (images-only or empty bundle)"
    fi

    cd - > /dev/null
}

# =============================================================================
# Pack Bundle
# =============================================================================

pack_bundle() {
    log_step "Packing Upgrade Bundle"

    local bundle_name
    if [[ "${INCLUDE_OPERATOR}" == "true" && -n "${TO_OPERATOR_VERSION}" ]]; then
        bundle_name="upgrade-bundle-${TO_OPERATOR_VERSION}.tar.gz"
    else
        bundle_name="upgrade-bundle-mongodb-$(date +%Y%m%d).tar.gz"
    fi

    local bundle_dir
    bundle_dir=$(dirname "${OUTPUT_DIR}")
    local source_dir
    source_dir=$(basename "${OUTPUT_DIR}")

    local dest_path="${bundle_dir}/${bundle_name}"

    log_info "  Creating: ${dest_path}"

    (cd "${bundle_dir}" && tar czf "${bundle_name}" "${source_dir}")

    local size
    size=$(du -sh "${dest_path}" | cut -f1)
    log_ok "Bundle created: ${dest_path} (${size})"

    echo ""
    echo "  Bundle path: ${dest_path}"
    echo "  Bundle size: ${size}"
}

# =============================================================================
# Summary
# =============================================================================

summary() {
    log_step "Bundle Preparation Complete"

    echo ""
    box "MongoDB Operator Upgrade Bundle Ready!"
    echo ""

    log_ok "Architecture : linux/${TARGET_ARCH}"
    log_ok "Output dir   : ${OUTPUT_DIR}"

    echo ""
    echo "  Components included:"
    [[ "${INCLUDE_OPERATOR}" == "true" ]] && \
        echo "    ✔ Operator       : ${FROM_OPERATOR_VERSION} → ${TO_OPERATOR_VERSION}"
    for pair in "${MONGODB_PAIRS[@]}"; do
        local from_ver="${pair%%:*}"
        local to_ver="${pair#*:}"
        echo "    ✔ MongoDB        : ${from_ver} → ${to_ver}"
    done
    [[ "${INCLUDE_BACKUP_AGENT}" == "true" ]] && \
        echo "    ✔ Backup Agent   : ${FROM_BACKUP_AGENT_VERSION} → ${TO_BACKUP_AGENT_VERSION}"

    echo ""
    echo "  Next steps:"
    echo "    1. Transfer bundle to offline environment:"
    echo "       scp $(dirname "${OUTPUT_DIR}")/upgrade-bundle-*.tar.gz user@offline-host:/opt/"
    echo "    2. (Optional) Dry-run to preview changes:"
    echo "       sudo ./upgrade-mongodb-operator.sh --bundle /opt/upgrade-bundle-*.tar.gz --dry-run"
    echo "    3. Apply the upgrade:"
    echo "       sudo ./upgrade-mongodb-operator.sh --bundle /opt/upgrade-bundle-*.tar.gz"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    ARCH_EXPLICIT=""
    parse_args "$@"
    init
    validate_tools
    add_helm_repos
    compute_delta
    download_helm_chart
    pull_and_save_images
    generate_manifest
    generate_checksums
    pack_bundle
    summary

    log_info "Bundle preparation finished."
    log_info "Logs: ${LOG_FILE}"
}

main "$@"
