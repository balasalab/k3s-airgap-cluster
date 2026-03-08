#!/usr/bin/env bash
# =============================================================================
# install-etcd.sh — Install etcd as a systemd service (offline/airgap)
#
# Installs the etcd key-value store used as the data store backend for K3s
# HA control plane clusters.  Run prepare-node.sh on this VM first.
#
# SINGLE-NODE ETCD (most common — one etcd VM backing multiple K3s CPs):
#   sudo ./install-etcd.sh --node-ip 192.168.64.30
#
# MULTI-NODE ETCD CLUSTER (production HA — 3 etcd nodes):
#   # On etcd node 1
#   sudo ./install-etcd.sh --node-ip 192.168.64.30 --node-name etcd-1 \
#     --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"
#
#   # On etcd node 2
#   sudo ./install-etcd.sh --node-ip 192.168.64.31 --node-name etcd-2 \
#     --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"
#
#   # On etcd node 3
#   sudo ./install-etcd.sh --node-ip 192.168.64.32 --node-name etcd-3 \
#     --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"
#
# After etcd is running, use the endpoint with install-k3s-ha-server.sh:
#   --datastore-endpoint http://192.168.64.30:2379
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging  (identical to other install-*.sh scripts)
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/etcd-install.log"
DEBUG=false
DRY_RUN=false

# =============================================================================
# Defaults
# =============================================================================
BUNDLE_PATH="/opt/offline-bundle"
NODE_IP=""
NODE_NAME=""                          # defaults to hostname
CLIENT_PORT="2379"                    # etcd client port
PEER_PORT="2380"                      # etcd peer port
CLUSTER_TOKEN="k3s-etcd-cluster"     # etcd cluster bootstrap token
INITIAL_CLUSTER=""                    # set automatically for single-node; override for multi-node
INITIAL_CLUSTER_STATE="new"          # "new" | "existing"
DATA_DIR="/var/lib/etcd"
ETCD_CONFIG_DIR="/etc/etcd"
ETCD_USER="etcd"

# =============================================================================
# Logging helpers
# =============================================================================
_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo -e "${GREEN}[INFO]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(_ts) $*" | tee -a "${LOG_FILE}"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" >&2; }
log_step() { echo -e "\n${BLUE}${BOLD}══ [STEP] $(_ts) $*${NC}" | tee -a "${LOG_FILE}"; }
log_ok()   { echo -e "${GREEN}  ✔${NC} $*" | tee -a "${LOG_FILE}"; }
log_debug(){ ${DEBUG} && echo -e "${CYAN}[DEBUG]${NC} $(_ts) $*" | tee -a "${LOG_FILE}" || true; }
run()      { log_debug "RUN: $*"; ${DRY_RUN} || "$@"; }

on_error() { log_error "Failed at line $1. Check ${LOG_FILE}"; exit 1; }
trap 'on_error $LINENO' ERR

# =============================================================================
# Idempotency
# =============================================================================
STEP_FILE="${LOG_DIR}/.etcd-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}install-etcd.sh${NC} — Install etcd data store for K3s HA clusters (offline)

${BOLD}USAGE${NC}
  sudo $0 --node-ip <IP> [OPTIONS]

${BOLD}REQUIRED${NC}
  --node-ip IP              This node's IP address (used for client + peer URLs)

${BOLD}OPTIONS${NC}
  --node-name NAME          etcd member name                   (default: hostname)
  --client-port PORT        etcd client listen port            (default: ${CLIENT_PORT})
  --peer-port PORT          etcd peer communication port       (default: ${PEER_PORT})
  --cluster-token TOKEN     etcd bootstrap cluster token       (default: ${CLUSTER_TOKEN})
  --initial-cluster SPEC    Comma-separated member=peerURL list for multi-node setup
                            (default: auto-built as single-node from --node-ip)
  --initial-cluster-state STATE   'new' or 'existing'         (default: ${INITIAL_CLUSTER_STATE})
  --data-dir PATH           etcd data directory                (default: ${DATA_DIR})
  --bundle-path PATH        Offline bundle path                (default: ${BUNDLE_PATH})
  --debug                   Enable debug output
  --dry-run                 Print commands without executing
  -h, --help                Show this help

${BOLD}SINGLE-NODE EXAMPLE${NC}
  sudo $0 --node-ip 192.168.64.30

${BOLD}MULTI-NODE CLUSTER EXAMPLE (run on each etcd VM)${NC}
  # Node 1
  sudo $0 --node-ip 192.168.64.30 --node-name etcd-1 \\
    --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"

  # Node 2
  sudo $0 --node-ip 192.168.64.31 --node-name etcd-2 \\
    --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"

  # Node 3
  sudo $0 --node-ip 192.168.64.32 --node-name etcd-3 \\
    --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"

${BOLD}JOINING EXISTING CLUSTER${NC}
  sudo $0 --node-ip 192.168.64.33 --node-name etcd-4 \\
    --initial-cluster-state existing \\
    --initial-cluster "etcd-1=http://192.168.64.30:2380,...,etcd-4=http://192.168.64.33:2380"

${BOLD}WORKFLOW${NC}
  1. Run this script on the etcd VM(s)
  2. Verify health: curl http://<etcd-ip>:2379/health
  3. Use the endpoint with K3s HA installer:
       sudo ./install-k3s-ha-server.sh --role first \\
         --datastore-endpoint http://<etcd-ip>:2379 ...
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-ip)               NODE_IP="${2:?--node-ip requires a value}"; shift 2 ;;
        --node-name)             NODE_NAME="${2:?--node-name requires a value}"; shift 2 ;;
        --client-port)           CLIENT_PORT="${2:?--client-port requires a value}"; shift 2 ;;
        --peer-port)             PEER_PORT="${2:?--peer-port requires a value}"; shift 2 ;;
        --cluster-token)         CLUSTER_TOKEN="${2:?--cluster-token requires a value}"; shift 2 ;;
        --initial-cluster)       INITIAL_CLUSTER="${2:?--initial-cluster requires a value}"; shift 2 ;;
        --initial-cluster-state) INITIAL_CLUSTER_STATE="${2:?--initial-cluster-state requires a value}"; shift 2 ;;
        --data-dir)              DATA_DIR="${2:?--data-dir requires a value}"; shift 2 ;;
        --bundle-path)           BUNDLE_PATH="${2:?--bundle-path requires a value}"; shift 2 ;;
        --debug)                 DEBUG=true; shift ;;
        --dry-run)               DRY_RUN=true; shift ;;
        -h|--help)               usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap — validate required args + initialise log directory
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]]     || { log_error "Run as root: sudo $0"; exit 1; }
[[ -n "${NODE_IP}" ]] || { log_error "--node-ip is required"; usage; exit 1; }

[[ "${INITIAL_CLUSTER_STATE}" == "new" || "${INITIAL_CLUSTER_STATE}" == "existing" ]] || {
    log_error "--initial-cluster-state must be 'new' or 'existing', got: '${INITIAL_CLUSTER_STATE}'"
    exit 1
}

# Default node name to hostname
[[ -n "${NODE_NAME}" ]] || NODE_NAME="$(hostname)"

# Auto-build single-node initial-cluster if not specified
if [[ -z "${INITIAL_CLUSTER}" ]]; then
    INITIAL_CLUSTER="${NODE_NAME}=http://${NODE_IP}:${PEER_PORT}"
fi

# =============================================================================
# 1. Verify offline bundle contains etcd binary
# =============================================================================
verify_bundle() {
    log_step "Verifying Offline Bundle at ${BUNDLE_PATH}"

    [[ -d "${BUNDLE_PATH}" ]] || {
        log_error "Bundle not found: ${BUNDLE_PATH}"
        log_error "Extract with: sudo tar -xzf offline-bundle.tar.gz -C /opt/"
        exit 1
    }

    local required=(
        "${BUNDLE_PATH}/binaries/etcd"
        "${BUNDLE_PATH}/binaries/etcdctl"
    )

    local missing=0
    for f in "${required[@]}"; do
        if [[ -f "${f}" ]]; then
            log_ok "${f##*/} — $(du -sh "${f}" | awk '{print $1}')"
        else
            log_error "MISSING: ${f}"
            missing=$((missing + 1))
        fi
    done

    if [[ "${missing}" -gt 0 ]]; then
        log_error "Bundle incomplete — etcd binaries not found."
        log_error "Re-run prepare-offline-bundle.sh on an internet-connected machine."
        exit 1
    fi

    log_ok "Bundle verified"
}

# =============================================================================
# 2. Check for existing etcd installation
# =============================================================================
check_existing_etcd() {
    log_step "Checking for Existing etcd Installation"

    if systemctl is-active --quiet etcd 2>/dev/null; then
        log_warn "etcd service is already running."
        log_warn "To reinstall: sudo systemctl stop etcd && sudo systemctl disable etcd"
        log_warn "Then delete the step file: sudo rm -f ${STEP_FILE}"

        # Show current health and exit gracefully
        log_info "Current etcd health:"
        curl -s --connect-timeout 5 \
            "http://127.0.0.1:${CLIENT_PORT}/health" 2>/dev/null \
            | tee -a "${LOG_FILE}" || true
        echo ""
        log_ok "etcd is already running — nothing to do"
        exit 0
    fi

    if command -v etcd &>/dev/null; then
        log_info "etcd binary found: $(etcd --version 2>/dev/null | head -1)"
    else
        log_ok "No existing etcd found — proceeding with installation"
    fi
}

# =============================================================================
# 3. Create etcd system user + directories
# =============================================================================
create_etcd_user_and_dirs() {
    step_done "etcd-user-dirs" && { log_info "etcd user and directories already set up, skipping."; return; }
    log_step "Creating etcd User and Directories"

    # Create dedicated system user (no login shell, no home dir)
    if id "${ETCD_USER}" &>/dev/null; then
        log_info "User '${ETCD_USER}' already exists"
    else
        run useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "etcd data store" \
            "${ETCD_USER}"
        log_ok "System user '${ETCD_USER}' created"
    fi

    # Create required directories
    run mkdir -p "${DATA_DIR}"
    run mkdir -p "${ETCD_CONFIG_DIR}"

    # Set ownership
    run chown -R "${ETCD_USER}:${ETCD_USER}" "${DATA_DIR}"
    run chown -R "${ETCD_USER}:${ETCD_USER}" "${ETCD_CONFIG_DIR}"
    run chmod 750 "${DATA_DIR}"
    run chmod 755 "${ETCD_CONFIG_DIR}"

    log_ok "Data directory      : ${DATA_DIR}"
    log_ok "Config directory    : ${ETCD_CONFIG_DIR}"
    log_ok "Ownership           : ${ETCD_USER}:${ETCD_USER}"

    mark_done "etcd-user-dirs"
}

# =============================================================================
# 4. Install etcd + etcdctl binaries
# =============================================================================
install_etcd_binaries() {
    if step_done "etcd-binaries" && [[ -f /usr/local/bin/etcd ]] && [[ -f /usr/local/bin/etcdctl ]]; then
        log_info "etcd binaries already installed, skipping."
        return
    fi

    # Stale step marker — binaries missing, retry
    if step_done "etcd-binaries"; then
        log_warn "Step marker exists but etcd binaries missing — retrying binary installation..."
        sed -i '/^etcd-binaries$/d' "${STEP_FILE}"
    fi

    log_step "Installing etcd Binaries"

    run cp "${BUNDLE_PATH}/binaries/etcd"    /usr/local/bin/etcd
    run cp "${BUNDLE_PATH}/binaries/etcdctl" /usr/local/bin/etcdctl

    run chmod +x /usr/local/bin/etcd
    run chmod +x /usr/local/bin/etcdctl

    log_ok "etcd    → /usr/local/bin/etcd"
    log_ok "etcdctl → /usr/local/bin/etcdctl"

    # Log installed version
    local ver
    ver="$(/usr/local/bin/etcd --version 2>/dev/null | head -1 || true)"
    log_info "Installed: ${ver}"

    mark_done "etcd-binaries"
}

# =============================================================================
# 5. Write etcd configuration file
# =============================================================================
write_etcd_config() {
    step_done "etcd-config" && { log_info "etcd config already written, skipping."; return; }
    log_step "Writing etcd Configuration"

    log_info "Node name           : ${NODE_NAME}"
    log_info "Node IP             : ${NODE_IP}"
    log_info "Client port         : ${CLIENT_PORT}"
    log_info "Peer port           : ${PEER_PORT}"
    log_info "Data directory      : ${DATA_DIR}"
    log_info "Cluster token       : ${CLUSTER_TOKEN}"
    log_info "Initial cluster     : ${INITIAL_CLUSTER}"
    log_info "Cluster state       : ${INITIAL_CLUSTER_STATE}"

    cat > "${ETCD_CONFIG_DIR}/etcd.conf" <<CONF
# =============================================================================
# etcd configuration — generated by install-etcd.sh
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Node: ${NODE_NAME} (${NODE_IP})
# =============================================================================

# Member
name:                        "${NODE_NAME}"
data-dir:                    "${DATA_DIR}"

# Client-to-server communication
listen-client-urls:          "http://0.0.0.0:${CLIENT_PORT}"
advertise-client-urls:       "http://${NODE_IP}:${CLIENT_PORT}"

# Peer-to-peer communication
listen-peer-urls:            "http://0.0.0.0:${PEER_PORT}"
initial-advertise-peer-urls: "http://${NODE_IP}:${PEER_PORT}"

# Cluster bootstrap
initial-cluster-token:       "${CLUSTER_TOKEN}"
initial-cluster:             "${INITIAL_CLUSTER}"
initial-cluster-state:       "${INITIAL_CLUSTER_STATE}"

# Logging
log-level:                   "info"
logger:                      "zap"
log-outputs:                 ["systemd/journal"]

# Automatic compaction (keep 1 hour of history, compact every 5 minutes)
auto-compaction-mode:        "periodic"
auto-compaction-retention:   "1h"

# Snapshot settings
snapshot-count:              10000
heartbeat-interval:          100
election-timeout:            1000

# Performance tuning
max-snapshots:               5
max-wals:                    5
quota-backend-bytes:         8589934592
CONF

    run chown "${ETCD_USER}:${ETCD_USER}" "${ETCD_CONFIG_DIR}/etcd.conf"
    run chmod 640 "${ETCD_CONFIG_DIR}/etcd.conf"

    log_ok "etcd config written to ${ETCD_CONFIG_DIR}/etcd.conf"
    mark_done "etcd-config"
}

# =============================================================================
# 6. Write systemd service unit
# =============================================================================
write_systemd_service() {
    step_done "etcd-systemd" && { log_info "etcd systemd unit already written, skipping."; return; }
    log_step "Writing etcd systemd Service Unit"

    cat > /etc/systemd/system/etcd.service <<UNIT
[Unit]
Description=etcd Key-Value Store
Documentation=https://etcd.io/docs
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${ETCD_USER}
Group=${ETCD_USER}

ExecStart=/usr/local/bin/etcd --config-file ${ETCD_CONFIG_DIR}/etcd.conf

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Restart policy
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Security hardening
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR}
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

    log_ok "Systemd unit written to /etc/systemd/system/etcd.service"
    mark_done "etcd-systemd"
}

# =============================================================================
# 7. Enable and start etcd
# =============================================================================
start_etcd() {
    step_done "etcd-started" && {
        # Verify it is actually running before trusting the marker
        if systemctl is-active --quiet etcd 2>/dev/null; then
            log_info "etcd service already running, skipping."
            return
        fi
        log_warn "Step marker exists but etcd not running — restarting..."
        sed -i '/^etcd-started$/d' "${STEP_FILE}"
    }

    log_step "Enabling and Starting etcd Service"

    run systemctl daemon-reload
    log_ok "systemd daemon reloaded"

    run systemctl enable etcd
    log_ok "etcd enabled on boot"

    run systemctl start etcd
    log_ok "etcd service started"

    mark_done "etcd-started"
}

# =============================================================================
# 8. Wait for etcd to become healthy
# =============================================================================
wait_for_etcd_health() {
    log_step "Waiting for etcd to Become Healthy"

    local timeout=120
    local elapsed=0
    local interval=5

    log_info "  Giving etcd 5s to initialise..."
    sleep 5
    elapsed=5

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local resp
        resp="$(curl -s --connect-timeout 3 \
            "http://127.0.0.1:${CLIENT_PORT}/health" 2>/dev/null || true)"

        if echo "${resp}" | grep -q '"health":"true"\|"health": "true"'; then
            log_ok "etcd is healthy (${elapsed}s)"

            # Show member list for multi-node clusters
            log_info "etcd member list:"
            /usr/local/bin/etcdctl \
                --endpoints="http://127.0.0.1:${CLIENT_PORT}" \
                member list 2>/dev/null \
                | tee -a "${LOG_FILE}" || true

            return 0
        fi

        log_info "  etcd not healthy yet... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    # Timed out — show journal for diagnosis
    log_error "etcd did not become healthy within ${timeout}s"
    log_error "Showing last 30 lines of etcd journal:"
    journalctl -u etcd --no-pager -n 30 2>/dev/null | tee -a "${LOG_FILE}" || true
    exit 1
}

# =============================================================================
# 9. Verify etcdctl connectivity
# =============================================================================
verify_etcdctl() {
    log_step "Verifying etcdctl Connectivity"

    local endpoint="http://127.0.0.1:${CLIENT_PORT}"

    # Endpoint health check
    local health_out
    health_out="$(/usr/local/bin/etcdctl \
        --endpoints="${endpoint}" \
        endpoint health 2>&1 || true)"
    log_info "Endpoint health:"
    echo "${health_out}" | tee -a "${LOG_FILE}"

    if echo "${health_out}" | grep -q "is healthy"; then
        log_ok "etcdctl confirmed endpoint healthy"
    else
        log_warn "etcdctl health check inconclusive — check manually if needed"
    fi

    # Write a test key and read it back
    if /usr/local/bin/etcdctl \
            --endpoints="${endpoint}" \
            put install-test "ok" &>/dev/null 2>&1; then

        local val
        val="$(/usr/local/bin/etcdctl \
            --endpoints="${endpoint}" \
            get install-test 2>/dev/null | tail -1 || true)"

        if [[ "${val}" == "ok" ]]; then
            log_ok "etcd read/write test passed"
            # Clean up test key
            /usr/local/bin/etcdctl \
                --endpoints="${endpoint}" \
                del install-test &>/dev/null 2>&1 || true
        else
            log_warn "etcd write succeeded but read returned unexpected value: '${val}'"
        fi
    else
        log_warn "etcd write test skipped (etcd may still be initialising)"
    fi
}

# =============================================================================
# 10. Output connection information for K3s HA
# =============================================================================
output_connection_info() {
    log_step "etcd Installation Complete"

    echo ""
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║        etcd Ready — K3s HA Connection Information         ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}etcd endpoint (client):${NC}"
    echo -e "  ${CYAN}http://${NODE_IP}:${CLIENT_PORT}${NC}"
    echo ""

    if [[ "${INITIAL_CLUSTER}" == *","* ]]; then
        # Multi-node: show all client endpoints
        echo -e "  ${BOLD}Multi-node cluster endpoints:${NC}"
        echo "${INITIAL_CLUSTER}" | tr ',' '\n' | while IFS='=' read -r name peerurl; do
            local host; host="$(echo "${peerurl}" | sed 's|http://||' | cut -d: -f1)"
            echo -e "  ${CYAN}http://${host}:${CLIENT_PORT}${NC}"
        done
        echo ""
    fi

    echo -e "  ${BOLD}Use with install-k3s-ha-server.sh (first control plane):${NC}"
    echo -e "  ${YELLOW}sudo ./install-k3s-ha-server.sh \\${NC}"
    echo -e "  ${YELLOW}    --role first \\${NC}"
    echo -e "  ${YELLOW}    --node-ip <CONTROL_PLANE_IP> \\${NC}"
    echo -e "  ${YELLOW}    --datastore-endpoint http://${NODE_IP}:${CLIENT_PORT}${NC}"
    echo ""
    echo -e "  ${BOLD}Quick health check:${NC}"
    echo -e "  ${YELLOW}curl http://${NODE_IP}:${CLIENT_PORT}/health${NC}"
    echo ""
    echo -e "  ${BOLD}Member list:${NC}"
    echo -e "  ${YELLOW}ETCDCTL_API=3 etcdctl --endpoints=http://${NODE_IP}:${CLIENT_PORT} member list${NC}"
    echo ""
    echo -e "  ${BOLD}Watch cluster status:${NC}"
    echo -e "  ${YELLOW}journalctl -u etcd -f${NC}"
    echo ""
    echo -e "  ${BOLD}Log file:${NC} ${LOG_FILE}"
    echo ""

    # Save connection details for easy reference
    cat > "${LOG_DIR}/etcd-connection.txt" <<INFO
# etcd connection information — generated by install-etcd.sh
# $(date -u +"%Y-%m-%dT%H:%M:%SZ")

ETCD_ENDPOINT=http://${NODE_IP}:${CLIENT_PORT}
ETCD_PEER_URL=http://${NODE_IP}:${PEER_PORT}
ETCD_NODE_NAME=${NODE_NAME}
ETCD_INITIAL_CLUSTER=${INITIAL_CLUSTER}
ETCD_DATA_DIR=${DATA_DIR}
INFO

    log_info "Connection details saved to ${LOG_DIR}/etcd-connection.txt"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │       etcd Data Store Installation            │"
    echo "  │   For K3s HA — Offline Bundle                 │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo -e "  Node: ${BOLD}${NODE_NAME}${NC} (${NODE_IP})"
    echo -e "  Mode: ${BOLD}$(echo "${INITIAL_CLUSTER}" | grep -o ',' | wc -l | awk '{print ($1+1) " member(s)"}')${NC}"
    echo ""

    verify_bundle
    check_existing_etcd
    create_etcd_user_and_dirs
    install_etcd_binaries
    write_etcd_config
    write_systemd_service
    start_etcd
    wait_for_etcd_health
    verify_etcdctl
    output_connection_info

    log_ok "etcd installation complete. Log: ${LOG_FILE}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. If this is a multi-node etcd cluster, run install-etcd.sh on the other etcd VMs"
    log_info "  2. Run install-k3s-ha-server.sh --role first on the first K3s control plane"
    log_info "  3. Run install-k3s-ha-server.sh --role additional on subsequent control planes"
    log_info "  4. Run install-k3s-agent.sh on each worker node"
    log_info "  5. Run install-cilium.sh on one control plane after all nodes have joined"
}

main "$@"
