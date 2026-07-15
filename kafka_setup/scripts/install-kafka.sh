#!/bin/bash

################################################################################
# Strimzi Kafka Operator — Offline Installation
#
# Purpose: Deploy a 3-broker Kafka HA cluster (Strimzi + KRaft) on an
#          offline K3s cluster using a pre-prepared bundle.
#
# Usage:   sudo ./install-kafka.sh --bundle-path /opt/kafka-bundle-prep
#
# Requirements:
#   - K3s cluster running (containerd runtime)
#   - 3 worker nodes with sufficient resources (2 CPU, 4 GB RAM per broker)
#   - Bundle prepared with prepare-kafka-bundle.sh
#   - kubectl configured to access cluster
#   - Helm 3.x installed on the system
#
################################################################################

set -euo pipefail

# =============================================================================
# Configuration & Defaults
# =============================================================================

BUNDLE_PATH="${BUNDLE_PATH:-/opt/kafka-bundle-prep}"
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_CLUSTER_NAME="kafka-cluster"
KAFKA_POOL_NAME="kafka"          # KafkaNodePool name → pods: kafka-cluster-kafka-0/1/2
HELM_BIN="${HELM_BIN:-helm}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

LOG_DIR="/var/log/k3s-install"
STEP_DIR="${LOG_DIR}/.steps-kafka"
LOG_FILE="${LOG_DIR}/kafka-install.log"

OPERATOR_READY_TIMEOUT=120      # seconds
KAFKA_READY_TIMEOUT=300         # seconds

# Populated by sourcing MANIFEST.env
STRIMZI_VERSION=""
KAFKA_VERSION=""
ARCH=""

# =============================================================================
# Color Codes
# =============================================================================

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
# Prerequisite Checks
# =============================================================================

check_prerequisites() {
    log_step "Checking Prerequisites"

    local failed=0

    # kubectl — must be able to reach the cluster
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        failed=1
    elif ! kubectl cluster-info &>/dev/null; then
        log_error "kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG})"
        log_error "Verify the cluster is running and kubeconfig is correct."
        failed=1
    else
        log_ok "kubectl: cluster reachable"
    fi

    # helm
    if ! command -v "${HELM_BIN}" &>/dev/null; then
        log_error "helm not found (tried '${HELM_BIN}'). Install helm 3.x and retry."
        failed=1
    else
        local helm_ver
        helm_ver=$("${HELM_BIN}" version --short 2>&1 | head -1)
        log_ok "helm: ${helm_ver}"
    fi

    # k3s ctr — needed to import container images into containerd
    if ! command -v k3s &>/dev/null || ! k3s ctr --help &>/dev/null 2>&1; then
        log_error "k3s ctr not available. This script requires K3s with containerd runtime."
        failed=1
    else
        log_ok "k3s ctr: available"
    fi

    if [[ "${failed}" -ne 0 ]]; then
        log_error "Prerequisite checks failed. Resolve the issues above and retry."
        exit 1
    fi

    log_ok "All prerequisites satisfied"
}

# =============================================================================
# Initialization
# =============================================================================

init() {
    mkdir -p "${LOG_DIR}" "${STEP_DIR}"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    export KUBECONFIG

    box "Strimzi Kafka Operator — Offline Installation"

    log_info "Configuration:"
    log_info "  Bundle Path    : ${BUNDLE_PATH}"
    log_info "  Namespace      : ${KAFKA_NAMESPACE}"
    log_info "  Cluster Name   : ${KAFKA_CLUSTER_NAME}"
    log_info "  Pool Name      : ${KAFKA_POOL_NAME}"
    log_info "  KUBECONFIG     : ${KUBECONFIG}"
    log_info "  Log file       : ${LOG_FILE}"
}

# =============================================================================
# Bundle Validation
# =============================================================================
# All checks happen BEFORE any cluster changes. If anything is missing, exit.

validate_bundle() {
    log_step "Validating Offline Bundle"

    if [[ ! -d "${BUNDLE_PATH}" ]]; then
        log_error "Bundle directory not found: ${BUNDLE_PATH}"
        log_error "Run prepare-kafka-bundle.sh first, then transfer the archive."
        exit 1
    fi

    if [[ ! -f "${BUNDLE_PATH}/MANIFEST.env" ]]; then
        log_error "MANIFEST.env not found in bundle: ${BUNDLE_PATH}/MANIFEST.env"
        exit 1
    fi
    log_ok "MANIFEST.env found"

    # Source MANIFEST.env to get version variables
    # shellcheck source=/dev/null
    source "${BUNDLE_PATH}/MANIFEST.env"

    local missing=0

    local operator_tar="${BUNDLE_PATH}/images/${STRIMZI_OPERATOR_TAR}"
    if [[ -f "${operator_tar}" ]]; then
        log_ok "images/${STRIMZI_OPERATOR_TAR}"
    else
        log_error "Missing image tar: ${operator_tar}"
        missing=1
    fi

    local kafka_tar="${BUNDLE_PATH}/images/${STRIMZI_KAFKA_TAR}"
    if [[ -f "${kafka_tar}" ]]; then
        log_ok "images/${STRIMZI_KAFKA_TAR}"
    else
        log_error "Missing image tar: ${kafka_tar}"
        missing=1
    fi

    local chart_file="${BUNDLE_PATH}/charts/${STRIMZI_CHART}"
    if [[ -f "${chart_file}" ]]; then
        log_ok "charts/${STRIMZI_CHART}"
    else
        log_error "Missing Helm chart: ${chart_file}"
        missing=1
    fi

    if [[ "${missing}" -ne 0 ]]; then
        log_error "Bundle validation failed. Correct the missing files and retry."
        exit 1
    fi

    STRIMZI_VERSION="${STRIMZI_VERSION}"
    KAFKA_VERSION="${KAFKA_VERSION}"

    log_ok "Bundle validated (Strimzi ${STRIMZI_VERSION} / Kafka ${KAFKA_VERSION} / linux/${ARCH})"
}

# =============================================================================
# Step 1 — Load Images into K3s containerd
# =============================================================================

load_images() {
    step_done "images-loaded" && {
        log_info "Container images already loaded — skipping."
        return
    }

    log_step "Step 1 — Loading Container Images into K3s"

    local operator_tar="${BUNDLE_PATH}/images/${STRIMZI_OPERATOR_TAR}"
    local kafka_tar="${BUNDLE_PATH}/images/${STRIMZI_KAFKA_TAR}"

    log_info "Importing: ${STRIMZI_OPERATOR_TAR}"
    if k3s ctr images import "${operator_tar}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Imported: ${STRIMZI_OPERATOR_TAR}"
    else
        log_error "Failed to import: ${operator_tar}"
        exit 1
    fi

    log_info "Importing: ${STRIMZI_KAFKA_TAR}"
    if k3s ctr images import "${kafka_tar}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Imported: ${STRIMZI_KAFKA_TAR}"
    else
        log_error "Failed to import: ${kafka_tar}"
        exit 1
    fi

    local strimzi_count
    strimzi_count=$(k3s ctr --namespace k8s.io images list 2>/dev/null | grep -c "strimzi" || echo 0)
    log_ok "Verified: ${strimzi_count} Strimzi image(s) in containerd"

    mark_done "images-loaded"
}

# =============================================================================
# Step 2 — Create Namespace
# =============================================================================

create_namespace() {
    step_done "namespace-created" && {
        log_info "Namespace already created — skipping."
        return
    }

    log_step "Step 2 — Creating Kafka Namespace"

    if kubectl create namespace "${KAFKA_NAMESPACE}" 2>/dev/null; then
        log_ok "Namespace '${KAFKA_NAMESPACE}' created"
    else
        log_info "Namespace '${KAFKA_NAMESPACE}' already exists"
    fi

    mark_done "namespace-created"
}

# =============================================================================
# Step 3 — Install Strimzi Operator via Helm
# =============================================================================

install_strimzi_operator() {
    step_done "operator-installed" && {
        log_info "Strimzi operator already installed — skipping."
        return
    }

    log_step "Step 3 — Installing Strimzi Operator"

    local chart="${BUNDLE_PATH}/charts/${STRIMZI_CHART}"

    log_info "Chart: ${chart}"

    if $HELM_BIN upgrade --install strimzi-operator "${chart}" \
        --namespace "${KAFKA_NAMESPACE}" \
        --set watchAnyNamespace=false \
        --timeout=5m \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Strimzi operator installed"
    else
        log_error "Strimzi operator installation failed"
        exit 1
    fi

    mark_done "operator-installed"
}

# =============================================================================
# Step 4 — Wait for Strimzi Operator Pod Ready
# =============================================================================

wait_for_operator() {
    log_step "Step 4 — Waiting for Strimzi Operator to be Ready"

    log_info "Waiting up to ${OPERATOR_READY_TIMEOUT}s for strimzi-cluster-operator..."

    if kubectl rollout status deployment/strimzi-cluster-operator \
        -n "${KAFKA_NAMESPACE}" \
        --timeout="${OPERATOR_READY_TIMEOUT}s" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Strimzi operator is Ready"
    else
        log_error "Strimzi operator did not become ready within ${OPERATOR_READY_TIMEOUT}s"
        log_error "Pod events:"
        kubectl describe pods -n "${KAFKA_NAMESPACE}" -l name=strimzi-cluster-operator 2>&1 | tee -a "${LOG_FILE}" || true
        exit 1
    fi
}

# =============================================================================
# Step 5 — Apply KafkaNodePool CR
# =============================================================================
# Pool name is "kafka" so that Strimzi names pods kafka-cluster-kafka-0/1/2
# (naming: <cluster-name>-<pool-name>-<index>)

apply_kafka_node_pool() {
    step_done "kafka-node-pool-applied" && {
        log_info "KafkaNodePool already applied — skipping."
        return
    }

    log_step "Step 5 — Applying KafkaNodePool CR"

    cat << EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: ${KAFKA_POOL_NAME}
  namespace: ${KAFKA_NAMESPACE}
  labels:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
spec:
  replicas: 3
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 50Gi
        deleteClaim: false
  resources:
    requests:
      memory: 2Gi
      cpu: "500m"
    limits:
      memory: 4Gi
      cpu: "2"
  template:
    pod:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: strimzi.io/component-type
                    operator: In
                    values:
                      - kafka
              topologyKey: kubernetes.io/hostname
EOF

    log_ok "KafkaNodePool '${KAFKA_POOL_NAME}' applied (3 replicas, roles: controller+broker)"
    mark_done "kafka-node-pool-applied"
}

# =============================================================================
# Step 6 — Apply Kafka CR (KRaft mode)
# =============================================================================

apply_kafka_cr() {
    step_done "kafka-cr-applied" && {
        log_info "Kafka CR already applied — skipping."
        return
    }

    log_step "Step 6 — Applying Kafka CR (KRaft mode)"

    cat << EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${KAFKA_CLUSTER_NAME}
  namespace: ${KAFKA_NAMESPACE}
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: "${KAFKA_VERSION}"
    metadataVersion: "4.0-IV0"
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF

    log_ok "Kafka CR '${KAFKA_CLUSTER_NAME}' applied (KRaft, PLAIN:9092, RF=3)"
    mark_done "kafka-cr-applied"
}

# =============================================================================
# Step 7 — Wait for Kafka Cluster READY
# =============================================================================

wait_for_kafka() {
    log_step "Step 7 — Waiting for Kafka Cluster to be Ready"

    log_info "Polling Kafka CR status (timeout: ${KAFKA_READY_TIMEOUT}s)..."

    local elapsed=0
    local interval=10

    while (( elapsed < KAFKA_READY_TIMEOUT )); do
        local ready
        ready=$(kubectl get kafka "${KAFKA_CLUSTER_NAME}" \
            -n "${KAFKA_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || echo "")

        if [[ "${ready}" == "True" ]]; then
            log_ok "Kafka cluster is Ready (${elapsed}s)"
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
    log_error "Pod status:"
    kubectl get pods -n "${KAFKA_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}" || true
    log_error "Strimzi operator logs (last 50 lines):"
    kubectl logs -n "${KAFKA_NAMESPACE}" \
        -l name=strimzi-cluster-operator \
        --tail=50 2>&1 | tee -a "${LOG_FILE}" || true
    exit 1
}

# =============================================================================
# Step 8 — Verify Cluster (create/produce/consume/delete test topic)
# =============================================================================

verify_cluster() {
    log_step "Step 8 — Verifying Kafka Cluster"

    local broker_pod="${KAFKA_CLUSTER_NAME}-${KAFKA_POOL_NAME}-0"
    local bootstrap="${KAFKA_CLUSTER_NAME}-kafka-bootstrap:9092"
    local test_topic="cluster-verify"

    log_info "Using broker pod: ${broker_pod}"
    log_info "Bootstrap:        ${bootstrap}"

    # Create test topic
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

    # Produce one message
    log_info "Producing test message..."
    if echo "kafka-verify-$(date -u +%s)" | kubectl exec -i "${broker_pod}" \
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

    # Consume one message (non-blocking, 10s timeout)
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
        log_warn "Consumer timed out — cluster may need more time to fully stabilize"
        log_warn "Re-run verification manually: kubectl exec ${broker_pod} -n ${KAFKA_NAMESPACE} -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server ${bootstrap} --topic ${test_topic} --from-beginning --max-messages 1"
    fi

    # Delete test topic
    kubectl exec "${broker_pod}" -n "${KAFKA_NAMESPACE}" -- \
        /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server "${bootstrap}" \
        --delete \
        --topic "${test_topic}" \
        2>&1 | tee -a "${LOG_FILE}" || true
    log_ok "Test topic deleted"
}

# =============================================================================
# Print Bootstrap Address and Summary
# =============================================================================

print_summary() {
    log_step "Installation Complete"
    echo ""
    box "Kafka Cluster Ready!"
    echo ""

    log_ok "Cluster name:  ${KAFKA_CLUSTER_NAME}"
    log_ok "Namespace:     ${KAFKA_NAMESPACE}"
    log_ok "Brokers:       3 (KRaft combined mode)"
    log_ok "Strimzi:       ${STRIMZI_VERSION}"
    log_ok "Kafka:         ${KAFKA_VERSION}"

    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║  Bootstrap address for workloads on this cluster:               ║"
    echo "  ║                                                                  ║"
    echo "  ║  kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092     ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    echo "  Useful commands:"
    echo "    # Check broker pods"
    echo "    kubectl get pods -n ${KAFKA_NAMESPACE}"
    echo ""
    echo "    # List topics"
    echo "    kubectl exec ${KAFKA_CLUSTER_NAME}-${KAFKA_POOL_NAME}-0 -n ${KAFKA_NAMESPACE} -- \\"
    echo "      /opt/kafka/bin/kafka-topics.sh --bootstrap-server ${KAFKA_CLUSTER_NAME}-kafka-bootstrap:9092 --list"
    echo ""
    echo "    # Check Kafka cluster status"
    echo "    kubectl get kafka ${KAFKA_CLUSTER_NAME} -n ${KAFKA_NAMESPACE} -o yaml | grep -A5 'status:'"
    echo ""
    echo "    # Strimzi operator logs"
    echo "    kubectl logs -n ${KAFKA_NAMESPACE} -l name=strimzi-cluster-operator -f"
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
            -h|--help)
                cat << 'HELP'
Usage: sudo ./install-kafka.sh [OPTIONS]

Options:
  --bundle-path PATH      Path to offline bundle directory
                          (default: /opt/kafka-bundle-prep)
  --namespace NAME        Kubernetes namespace for Kafka (default: kafka)
  --kubeconfig PATH       Path to kubeconfig (default: /etc/rancher/k3s/k3s.yaml)
  -h, --help              Show this help message

Examples:
  sudo ./install-kafka.sh --bundle-path /opt/kafka-bundle-prep
  sudo ./install-kafka.sh --bundle-path /mnt/usb/kafka-bundle-prep --namespace kafka

Re-run safety:
  The script tracks completed steps in /var/log/k3s-install/.steps-kafka/.
  Re-running after a partial failure resumes from where it stopped.
  To force a full re-run: sudo rm -rf /var/log/k3s-install/.steps-kafka/
HELP
                exit 0
                ;;
            *)
                log_error "Unknown option: $1. Use --help for usage."
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
    check_prerequisites
    validate_bundle   # sources MANIFEST.env, sets STRIMZI_VERSION/KAFKA_VERSION/ARCH
    load_images
    create_namespace
    install_strimzi_operator
    wait_for_operator
    apply_kafka_node_pool
    apply_kafka_cr
    wait_for_kafka
    verify_cluster
    print_summary

    log_info "Kafka installation finished successfully"
    log_info "Logs available at: ${LOG_FILE}"
}

main "$@"
