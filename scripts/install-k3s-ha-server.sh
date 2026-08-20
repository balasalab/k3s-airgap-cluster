#!/usr/bin/env bash
# =============================================================================
# install-k3s-ha-server.sh — Install K3s Control Plane in HA mode (offline)
#
# Supports TWO etcd backends:
#
#   Option A — External etcd (dedicated etcd node):
#     --datastore-endpoint http://192.168.64.30:2379
#
#   Option B — Embedded etcd (no dedicated etcd node):
#     --embedded-etcd
#
# TWO ROLES:
#   --role first       → initialises the cluster (run once on first CP)
#   --role additional  → joins an existing CP (run on every subsequent CP)
#
# Usage (Option A — external etcd):
#   sudo ./install-k3s-ha-server.sh --role first --node-ip 192.168.64.21 \
#       --datastore-endpoint http://192.168.64.30:2379
#
#   sudo ./install-k3s-ha-server.sh --role additional --node-ip 192.168.64.22 \
#       --datastore-endpoint http://192.168.64.30:2379 \
#       --cluster-token <TOKEN_FROM_FIRST_CP>
#
# Usage (Option B — embedded etcd):
#   sudo ./install-k3s-ha-server.sh --role first --node-ip 192.168.64.21 \
#       --embedded-etcd
#
#   sudo ./install-k3s-ha-server.sh --role additional --node-ip 192.168.64.22 \
#       --embedded-etcd --server-ip 192.168.64.21 \
#       --cluster-token <TOKEN_FROM_FIRST_CP>
# =============================================================================
set -euo pipefail

# =============================================================================
# Colours / logging  (identical to install-k3s-server.sh)
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/k3s-install"
LOG_FILE="${LOG_DIR}/k3s-ha-server-install.log"
DEBUG=false
DRY_RUN=false

# =============================================================================
# Defaults
# =============================================================================
BUNDLE_PATH="/opt/offline-bundle"
NODE_IP=""
NODE_NAME=""                # defaults to hostname
ROLE=""                     # "first" | "additional"
DATASTORE_ENDPOINT=""       # Option A: external etcd e.g. http://192.168.64.30:2379
EMBEDDED_ETCD=false         # Option B: use K3s embedded etcd (--cluster-init)
SERVER_IP=""                # Option B additional: IP of first CP to join
CLUSTER_TOKEN=""            # required for --role additional
LOAD_BALANCER_IP=""         # optional: VIP in front of control planes
CLUSTER_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CLUSTER_DNS="10.96.0.10"

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
STEP_FILE="${LOG_DIR}/.ha-server-steps"
step_done() { grep -qxF "$1" "${STEP_FILE}" 2>/dev/null; }
mark_done() { echo "$1" >> "${STEP_FILE}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
${BOLD}install-k3s-ha-server.sh${NC} — Install K3s control plane in HA mode (offline)

${BOLD}USAGE${NC}
  sudo $0 --role <first|additional> --node-ip <IP> [--datastore-endpoint URL | --embedded-etcd] [OPTIONS]

${BOLD}REQUIRED${NC}
  --role first|additional     'first' initialises the cluster; 'additional' joins it
  --node-ip IP                This node's IP address

${BOLD}ETCD BACKEND (choose one)${NC}
  --datastore-endpoint URL    Option A: external etcd  (e.g. http://192.168.64.30:2379)
  --embedded-etcd             Option B: K3s built-in embedded etcd (no separate etcd VM)

${BOLD}REQUIRED FOR --role additional${NC}
  --cluster-token TOKEN       Node join token from the first control plane
  --server-ip IP              Option B only: IP of the first control plane to join

${BOLD}OPTIONS${NC}
  --node-name NAME            Unique K3s node name           (default: hostname)
  --load-balancer-ip IP       Load balancer VIP — added to TLS SANs (optional)
  --cluster-cidr CIDR         Pod network CIDR               (default: ${CLUSTER_CIDR})
  --service-cidr CIDR         Service network CIDR           (default: ${SERVICE_CIDR})
  --bundle-path PATH          Offline bundle path            (default: ${BUNDLE_PATH})
  --debug                     Enable debug output
  --dry-run                   Print commands without executing
  -h, --help                  Show this help

${BOLD}EXAMPLES — Option A (external etcd)${NC}
  # First control plane
  sudo $0 --role first \\
    --node-ip 192.168.64.21 \\
    --datastore-endpoint http://192.168.64.30:2379 \\
    --load-balancer-ip 192.168.64.20

  # Second control plane
  sudo $0 --role additional \\
    --node-ip 192.168.64.22 \\
    --datastore-endpoint http://192.168.64.30:2379 \\
    --cluster-token 'K10xxx::server:yyy' \\
    --load-balancer-ip 192.168.64.20

${BOLD}EXAMPLES — Option B (embedded etcd, no dedicated etcd VM)${NC}
  # First control plane — bootstraps embedded etcd cluster
  sudo $0 --role first \\
    --node-ip 192.168.64.21 \\
    --embedded-etcd \\
    --load-balancer-ip 192.168.64.20

  # Second control plane — joins embedded etcd cluster via first CP
  sudo $0 --role additional \\
    --node-ip 192.168.64.22 \\
    --embedded-etcd \\
    --server-ip 192.168.64.21 \\
    --cluster-token 'K10xxx::server:yyy' \\
    --load-balancer-ip 192.168.64.20
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)                ROLE="${2:?--role requires first|additional}"; shift 2 ;;
        --node-ip)             NODE_IP="${2:?--node-ip requires a value}"; shift 2 ;;
        --node-name)           NODE_NAME="${2:?--node-name requires a value}"; shift 2 ;;
        --datastore-endpoint)  DATASTORE_ENDPOINT="${2:?--datastore-endpoint requires a value}"; shift 2 ;;
        --embedded-etcd)       EMBEDDED_ETCD=true; shift ;;
        --server-ip)           SERVER_IP="${2:?--server-ip requires a value}"; shift 2 ;;
        --cluster-token)       CLUSTER_TOKEN="${2:?--cluster-token requires a value}"; shift 2 ;;
        --load-balancer-ip)    LOAD_BALANCER_IP="${2:?--load-balancer-ip requires a value}"; shift 2 ;;
        --cluster-cidr)        CLUSTER_CIDR="${2:?}"; shift 2 ;;
        --service-cidr)        SERVICE_CIDR="${2:?}"; shift 2 ;;
        --bundle-path)         BUNDLE_PATH="${2:?}"; shift 2 ;;
        --debug)               DEBUG=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap — validate required args
# =============================================================================
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

[[ $EUID -eq 0 ]]     || { log_error "Run as root: sudo $0"; exit 1; }
[[ -n "${NODE_IP}" ]] || { log_error "--node-ip is required"; usage; exit 1; }
[[ -n "${ROLE}" ]]    || { log_error "--role is required (first|additional)"; usage; exit 1; }

[[ "${ROLE}" == "first" || "${ROLE}" == "additional" ]] || {
    log_error "--role must be 'first' or 'additional', got: '${ROLE}'"
    exit 1
}

# Exactly one etcd backend must be chosen
if [[ "${EMBEDDED_ETCD}" == "false" && -z "${DATASTORE_ENDPOINT}" ]]; then
    log_error "Specify an etcd backend:"
    log_error "  Option A (external etcd): --datastore-endpoint http://<etcd-ip>:2379"
    log_error "  Option B (embedded etcd): --embedded-etcd"
    usage; exit 1
fi

if [[ "${EMBEDDED_ETCD}" == "true" && -n "${DATASTORE_ENDPOINT}" ]]; then
    log_error "--embedded-etcd and --datastore-endpoint are mutually exclusive"
    exit 1
fi

# Embedded etcd additional CP requires --server-ip to know which CP to join
if [[ "${EMBEDDED_ETCD}" == "true" && "${ROLE}" == "additional" && -z "${SERVER_IP}" ]]; then
    log_error "--server-ip is required for --embedded-etcd --role additional"
    log_error "Set it to the IP of the first control plane (e.g. --server-ip 192.168.64.21)"
    exit 1
fi

if [[ "${ROLE}" == "additional" && -z "${CLUSTER_TOKEN}" ]]; then
    log_error "--cluster-token is required when --role is 'additional'"
    log_error "Get it from the first control plane:"
    log_error "  sudo cat /var/lib/rancher/k3s/server/node-token"
    exit 1
fi

# Default node name to hostname
[[ -n "${NODE_NAME}" ]] || NODE_NAME="$(hostname)"

# =============================================================================
# 1. Offline bundle validation
# =============================================================================
verify_bundle() {
    log_step "Verifying Offline Bundle at ${BUNDLE_PATH}"

    [[ -d "${BUNDLE_PATH}" ]] || {
        log_error "Bundle not found: ${BUNDLE_PATH}"
        log_error "Extract with: sudo tar -xzf offline-bundle.tar.gz -C /opt/"
        exit 1
    }

    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    local required=(
        "${BUNDLE_PATH}/binaries/k3s"
        "${BUNDLE_PATH}/binaries/install.sh"
        "${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
    )

    local missing=0
    for f in "${required[@]}"; do
        [[ -f "${f}" ]] && log_ok "${f##*/}" || { log_error "MISSING: ${f}"; missing=$((missing+1)); }
    done

    [[ "${missing}" -eq 0 ]] || { log_error "Bundle incomplete."; exit 1; }
    log_ok "Bundle verified"
}

# =============================================================================
# 2. Verify etcd is reachable (Option A only — skipped for embedded etcd)
# =============================================================================
verify_etcd() {
    if [[ "${EMBEDDED_ETCD}" == "true" ]]; then
        log_step "etcd Backend: Embedded (K3s built-in) — skipping external etcd check"
        if [[ "${ROLE}" == "first" ]]; then
            log_ok "First CP will bootstrap embedded etcd cluster via --cluster-init"
        else
            log_ok "Additional CP will join embedded etcd cluster via --server https://${SERVER_IP}:6443"
        fi
        return
    fi

    log_step "Verifying etcd Data Store (${DATASTORE_ENDPOINT})"

    # DATASTORE_ENDPOINT may be a single URL or a comma-separated list
    # (multi-node etcd cluster, e.g. http://etcd-1:2379,http://etcd-2:2379,http://etcd-3:2379).
    # Only one member needs to answer here — K3s's own etcd client handles
    # failover across all listed members at runtime.
    local etcd_endpoints
    IFS=',' read -ra etcd_endpoints <<< "${DATASTORE_ENDPOINT}"

    local retries=5
    local wait_s=3
    local etcd_ok=false
    local healthy_ep=""

    for ((i=1; i<=retries; i++)); do
        for ep in "${etcd_endpoints[@]}"; do
            local resp
            resp="$(curl -s --connect-timeout 5 "${ep}/health" 2>/dev/null || true)"
            if echo "${resp}" | grep -q '"health":"true"\|"health": "true"'; then
                etcd_ok=true
                healthy_ep="${ep}"
                break 2
            fi
        done
        log_info "  etcd not reachable yet (attempt ${i}/${retries}) — retrying in ${wait_s}s..."
        [[ ${i} -lt ${retries} ]] && sleep "${wait_s}"
    done

    if ! ${etcd_ok}; then
        log_warn "etcd health check did not confirm 'healthy' on any endpoint — checking TCP connectivity..."

        local tcp_ok=false
        for ep in "${etcd_endpoints[@]}"; do
            local etcd_host; etcd_host="$(echo "${ep}" | sed 's|http[s]*://||' | cut -d: -f1)"
            local etcd_port; etcd_port="$(echo "${ep}" | sed 's|http[s]*://||' | cut -d: -f2)"

            if timeout 5 bash -c ">/dev/tcp/${etcd_host}/${etcd_port}" 2>/dev/null; then
                log_warn "TCP to ${ep} is open — etcd may be starting. Proceeding."
                tcp_ok=true
                break
            fi
        done

        ${tcp_ok} || {
            log_error "Cannot reach etcd at any of: ${DATASTORE_ENDPOINT}"
            log_error "Ensure etcd is running on the etcd node(s):"
            log_error "  sudo systemctl status etcd"
            log_error "  sudo systemctl start etcd"
            exit 1
        }
    else
        log_ok "etcd is healthy at ${healthy_ep}"
    fi
}

# =============================================================================
# 3. Idempotency — detect existing installation
# =============================================================================
check_existing_install() {
    log_step "Checking for Existing K3s Installation"

    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_warn "K3s server is already running."
        log_warn "To reinstall, run rollback.sh --server first."
        SKIP_INSTALL=true
    else
        SKIP_INSTALL=false
        log_ok "No running K3s server — proceeding with ${ROLE} control plane install"
    fi

    if command -v k3s &>/dev/null; then
        log_info "k3s binary found: $(k3s --version 2>/dev/null | head -1)"
    fi
}

# =============================================================================
# 4. Copy K3s artifacts from bundle
# =============================================================================
prepare_k3s_files() {
    # Check if already done AND files actually exist
    if step_done "ha-k3s-files" && [[ -f /usr/local/bin/k3s ]]; then
        log_info "K3s files already prepared, skipping."
        return
    fi

    # Step marker stale — binary missing, retry
    if step_done "ha-k3s-files"; then
        log_warn "Step marker exists but k3s binary missing — retrying file preparation..."
        sed -i '/^ha-k3s-files$/d' "${STEP_FILE}"
    fi

    log_step "Preparing K3s Files from Bundle"

    local arch_raw; arch_raw="$(uname -m)"
    local arch; [[ "${arch_raw}" == "aarch64" ]] && arch="arm64" || arch="amd64"

    run cp "${BUNDLE_PATH}/binaries/k3s" /usr/local/bin/k3s
    run chmod +x /usr/local/bin/k3s
    log_ok "k3s binary → /usr/local/bin/k3s"

    run mkdir -p /var/lib/rancher/k3s/agent/images
    local airgap_img="${BUNDLE_PATH}/images/k3s-airgap-images-${arch}.tar.gz"
    if [[ -f "${airgap_img}" ]]; then
        run cp "${airgap_img}" /var/lib/rancher/k3s/agent/images/
        log_ok "Airgap images → /var/lib/rancher/k3s/agent/images/"
    fi

    for bin in kubectl helm cilium crictl; do
        local src="${BUNDLE_PATH}/binaries/${bin}"
        [[ -f "${src}" ]] || continue
        run cp "${src}" "/usr/local/bin/${bin}"
        run chmod +x "/usr/local/bin/${bin}"
        log_ok "${bin} → /usr/local/bin/"
    done

    mark_done "ha-k3s-files"
}

# =============================================================================
# 5. Install K3s HA server
# =============================================================================
install_k3s_ha_server() {
    if [[ "${SKIP_INSTALL:-false}" == "true" ]]; then
        log_info "K3s already running — skipping install."
        return
    fi

    step_done "ha-server-install" && { log_info "K3s HA install already completed, skipping."; return; }

    local etcd_mode; [[ "${EMBEDDED_ETCD}" == "true" ]] && etcd_mode="embedded" || etcd_mode="external"
    log_step "Installing K3s Control Plane (role: ${ROLE}, etcd: ${etcd_mode})"

    log_info "Role              : ${ROLE}"
    log_info "Node IP           : ${NODE_IP}"
    log_info "Node Name         : ${NODE_NAME}"
    log_info "etcd Backend      : ${etcd_mode}"
    [[ "${EMBEDDED_ETCD}" == "false" ]] && log_info "Data Store        : ${DATASTORE_ENDPOINT}"
    [[ "${EMBEDDED_ETCD}" == "true" && "${ROLE}" == "additional" ]] && log_info "Join Server       : https://${SERVER_IP}:6443"
    log_info "Load Balancer IP  : ${LOAD_BALANCER_IP:-<none>}"
    log_info "Cluster CIDR      : ${CLUSTER_CIDR}"
    log_info "Service CIDR      : ${SERVICE_CIDR}"

    # Common flags for all control planes
    local k3s_exec_flags=(
        "server"
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
        "--disable=traefik"
        "--disable=servicelb"
        "--cluster-cidr=${CLUSTER_CIDR}"
        "--service-cidr=${SERVICE_CIDR}"
        "--cluster-dns=${CLUSTER_DNS}"
        "--node-ip=${NODE_IP}"
        "--node-name=${NODE_NAME}"
        "--tls-san=${NODE_IP}"
        "--write-kubeconfig-mode=644"
    )

    # Add load balancer IP to TLS SANs so kubeconfig works through LB
    if [[ -n "${LOAD_BALANCER_IP}" ]]; then
        k3s_exec_flags+=("--tls-san=${LOAD_BALANCER_IP}")
        log_info "TLS SAN           : ${NODE_IP}, ${LOAD_BALANCER_IP}"
    fi

    # ── Option B: embedded etcd ───────────────────────────────────────────────
    if [[ "${EMBEDDED_ETCD}" == "true" ]]; then
        if [[ "${ROLE}" == "first" ]]; then
            # --cluster-init bootstraps a new embedded etcd cluster
            k3s_exec_flags+=("--cluster-init")
            log_info "Bootstrapping new embedded etcd cluster (--cluster-init)"
        else
            # Additional CP joins via the first CP's API server
            k3s_exec_flags+=("--server=https://${SERVER_IP}:6443")
            log_info "Joining embedded etcd cluster via https://${SERVER_IP}:6443"
        fi

        local install_env=(
            INSTALL_K3S_SKIP_DOWNLOAD=true
            INSTALL_K3S_BIN_DIR=/usr/local/bin
            "INSTALL_K3S_EXEC=${k3s_exec_flags[*]}"
            "K3S_NODE_IP=${NODE_IP}"
            "K3S_TOKEN=${CLUSTER_TOKEN:-}"
        )

    # ── Option A: external etcd ───────────────────────────────────────────────
    else
        local install_env=(
            INSTALL_K3S_SKIP_DOWNLOAD=true
            INSTALL_K3S_BIN_DIR=/usr/local/bin
            "INSTALL_K3S_EXEC=${k3s_exec_flags[*]}"
            "K3S_DATASTORE_ENDPOINT=${DATASTORE_ENDPOINT}"
            "K3S_NODE_IP=${NODE_IP}"
        )

        if [[ "${ROLE}" == "additional" ]]; then
            install_env+=("K3S_TOKEN=${CLUSTER_TOKEN}")
            log_info "Joining existing HA cluster using provided token"
        else
            log_info "Initialising new HA cluster (first control plane)"
        fi
    fi

    log_debug "K3s exec flags: ${k3s_exec_flags[*]}"

    env "${install_env[@]}" \
        bash "${BUNDLE_PATH}/binaries/install.sh" 2>&1 | tee -a "${LOG_FILE}"

    # NOTE: mark_done for "ha-server-install" happens in wait_for_k3s, not here.
    # install.sh only installs + starts the systemd unit — it returns 0 even if
    # k3s then crash-loops. Marking done here caused re-runs to silently skip
    # a broken install and just time out waiting for an API server that was
    # never actually (re)started.
    log_ok "K3s installer finished — waiting for the API server to confirm health"
}

# =============================================================================
# 6. Diagnostics — dump service state + known-cause hints on failure
# =============================================================================
dump_k3s_diagnostics() {
    log_error "── systemctl status k3s ──"
    systemctl status k3s --no-pager 2>&1 | tee -a "${LOG_FILE}" >&2 || true

    log_error "── journalctl -u k3s (last 50 lines) ──"
    local journal
    journal="$(journalctl -u k3s --no-pager -n 50 2>&1 || true)"
    echo "${journal}" | tee -a "${LOG_FILE}" >&2

    if echo "${journal}" | grep -q 'SEGV\|code=killed'; then
        log_error "Detected a crashed (SIGSEGV) k3s process."
        log_error "This is almost always stale/corrupted local state from a previous failed install — not hardware."
        log_error "Fix:"
        log_error "  sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s"
        log_error "  sudo rm -f ${STEP_FILE}"
        log_error "  then re-run this script"
    elif echo "${journal}" | grep -q 'bootstrap data already found'; then
        log_error "Detected mismatched bootstrap data in the etcd datastore."
        log_error "etcd already holds cluster data encrypted with a different token than this install used."
        log_error "Fix (run on the etcd node — do NOT hand-run 'rm -rf .../*', it silently no-ops under sudo):"
        log_error "  sudo ./rollback.sh --etcd --force"
        log_error "  then re-run this script"
    fi
}

# =============================================================================
# 7. Wait for K3s API server to be healthy
# =============================================================================
wait_for_k3s() {
    log_step "Waiting for K3s API Server"

    log_info "  Giving K3s 15s to initialise..."
    sleep 15

    local timeout=300
    local elapsed=15
    local interval=5
    local max_restarts=5
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Try to get nodes with kubectl — works if API is responsive
        if kubectl get nodes &>/dev/null; then
            log_ok "K3s API server is responsive (${elapsed}s)"
            step_done "ha-server-install" || mark_done "ha-server-install"
            return 0
        fi

        # Bail early if the service is crash-looping instead of burning the full timeout
        local restarts
        restarts="$(systemctl show k3s -p NRestarts --value 2>/dev/null || echo 0)"
        if [[ "${restarts}" =~ ^[0-9]+$ ]] && [[ "${restarts}" -ge "${max_restarts}" ]]; then
            log_error "k3s.service has restarted ${restarts} times — it is crash-looping, not just slow to start."
            dump_k3s_diagnostics
            exit 1
        fi

        log_info "  Waiting for API server... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_error "K3s API server did not become responsive within ${timeout}s"
    dump_k3s_diagnostics
    exit 1
}

# =============================================================================
# 8. Configure kubectl
# =============================================================================
configure_kubectl() {
    step_done "ha-kubectl-config" && { log_info "kubectl already configured, skipping."; return; }
    log_step "Configuring kubectl Access"

    local kc="/etc/rancher/k3s/k3s.yaml"
    export KUBECONFIG="${kc}"

    # ── root ──────────────────────────────────────────────────────────────────
    mkdir -p /root/.kube
    run cp "${kc}" /root/.kube/config
    run chmod 600 /root/.kube/config

    for rcfile in /root/.bashrc /root/.profile; do
        if [[ -f "${rcfile}" ]] && ! grep -q "KUBECONFIG=" "${rcfile}" 2>/dev/null; then
            echo "export KUBECONFIG=${kc}" >> "${rcfile}"
            log_ok "KUBECONFIG added to ${rcfile}"
        fi
    done

    # ── ubuntu user ───────────────────────────────────────────────────────────
    if id ubuntu &>/dev/null; then
        local home_dir="/home/ubuntu"
        mkdir -p "${home_dir}/.kube"
        run cp "${kc}" "${home_dir}/.kube/config"
        run chown -R ubuntu:ubuntu "${home_dir}/.kube"
        run chmod 600 "${home_dir}/.kube/config"

        if ! grep -q "KUBECONFIG=" "${home_dir}/.bashrc" 2>/dev/null; then
            echo "export KUBECONFIG=${kc}" >> "${home_dir}/.bashrc"
            log_ok "KUBECONFIG added to ${home_dir}/.bashrc"
        fi

        for rcfile in "${home_dir}/.profile" "${home_dir}/.bash_profile"; do
            if [[ -f "${rcfile}" ]] && ! grep -q "KUBECONFIG=" "${rcfile}" 2>/dev/null; then
                echo "export KUBECONFIG=${kc}" >> "${rcfile}"
                log_ok "KUBECONFIG added to ${rcfile}"
            fi
        done
    fi

    # ── system-wide (all users + sudo sessions) ───────────────────────────────
    cat > /etc/profile.d/k3s-kubectl.sh <<PROFILE
# K3s kubeconfig — set by install-k3s-ha-server.sh
export KUBECONFIG=${kc}
PROFILE
    chmod 644 /etc/profile.d/k3s-kubectl.sh
    log_ok "KUBECONFIG set system-wide via /etc/profile.d/k3s-kubectl.sh"

    if ! grep -q "KUBECONFIG=" /etc/environment 2>/dev/null; then
        echo "KUBECONFIG=${kc}" >> /etc/environment
        log_ok "KUBECONFIG added to /etc/environment (applies to sudo sessions)"
    fi

    log_ok "kubectl ready — works for all users without 'export KUBECONFIG=...'"
    log_info "  Regular user : kubectl get nodes"
    log_info "  As root/sudo : sudo kubectl get nodes"
    mark_done "ha-kubectl-config"
}

# =============================================================================
# 9. Verify node joined cluster
# =============================================================================
verify_node_joined() {
    log_step "Verifying Control Plane Node Joined Cluster"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local timeout=120
    local elapsed=0
    local interval=10

    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Check if this node appears in the cluster
        if kubectl get node "${NODE_NAME}" &>/dev/null 2>&1; then
            local status
            status="$(kubectl get node "${NODE_NAME}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
            log_ok "Node '${NODE_NAME}' found in cluster (status: ${status:-Pending})"

            # Show all control plane nodes
            log_info "Current control plane nodes:"
            kubectl get nodes -l node-role.kubernetes.io/control-plane \
                -o wide 2>/dev/null | tee -a "${LOG_FILE}" || true
            return 0
        fi
        log_info "  Node '${NODE_NAME}' not yet visible in cluster... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_warn "Node '${NODE_NAME}' not yet visible — may still be registering"
    log_warn "Check manually: kubectl get nodes"
}

# =============================================================================
# 10. Output join information
# =============================================================================
output_join_info() {
    log_step "Cluster Join Information"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local token_file="/var/lib/rancher/k3s/server/node-token"
    local retries=0
    while [[ ! -f "${token_file}" && ${retries} -lt 30 ]]; do
        sleep 2
        retries=$((retries + 1))
    done

    if [[ -f "${token_file}" ]]; then
        local token; token="$(cat "${token_file}")"
        local lb_or_node_ip="${LOAD_BALANCER_IP:-${NODE_IP}}"

        echo ""
        echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║        HA Cluster Join Information                     ║${NC}"
        echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${BOLD}Cluster token:${NC}"
        echo -e "  ${CYAN}${token}${NC}"
        echo ""
        echo -e "  ${BOLD}Add another control plane:${NC}"
        if [[ "${EMBEDDED_ETCD}" == "true" ]]; then
            echo -e "  ${YELLOW}sudo ./install-k3s-ha-server.sh \\${NC}"
            echo -e "  ${YELLOW}    --role additional \\${NC}"
            echo -e "  ${YELLOW}    --node-ip <NEW_CP_IP> \\${NC}"
            echo -e "  ${YELLOW}    --embedded-etcd \\${NC}"
            echo -e "  ${YELLOW}    --server-ip ${NODE_IP} \\${NC}"
            echo -e "  ${YELLOW}    --cluster-token '${token}'${NC}"
        else
            echo -e "  ${YELLOW}sudo ./install-k3s-ha-server.sh \\${NC}"
            echo -e "  ${YELLOW}    --role additional \\${NC}"
            echo -e "  ${YELLOW}    --node-ip <NEW_CP_IP> \\${NC}"
            echo -e "  ${YELLOW}    --datastore-endpoint ${DATASTORE_ENDPOINT} \\${NC}"
            echo -e "  ${YELLOW}    --cluster-token '${token}'${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}Add worker nodes:${NC}"
        echo -e "  ${YELLOW}sudo ./install-k3s-agent.sh \\${NC}"
        echo -e "  ${YELLOW}    --server-ip ${lb_or_node_ip} \\${NC}"
        echo -e "  ${YELLOW}    --token '${token}' \\${NC}"
        echo -e "  ${YELLOW}    --node-name worker-01${NC}"
        echo ""

        # Save token for reference
        echo "${token}" > "${LOG_DIR}/node-token.txt"
        log_info "Token saved to ${LOG_DIR}/node-token.txt"
    else
        log_warn "Token file not available at ${token_file}"
        log_warn "Retrieve manually: sudo cat ${token_file}"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌───────────────────────────────────────────────┐"
    echo "  │   K3s HA Control Plane Installation           │"
    echo "  │   Cilium + WireGuard — Offline Bundle         │"
    echo "  └───────────────────────────────────────────────┘"
    echo -e "${NC}"
    local etcd_mode; [[ "${EMBEDDED_ETCD}" == "true" ]] && etcd_mode="embedded etcd" || etcd_mode="external etcd"
    echo -e "  Role: ${BOLD}${ROLE}${NC} control plane  |  etcd: ${BOLD}${etcd_mode}${NC}"
    echo ""

    verify_bundle
    verify_etcd
    check_existing_install
    prepare_k3s_files
    install_k3s_ha_server
    wait_for_k3s
    configure_kubectl
    verify_node_joined

    # Only the first CP outputs join info (it initialised the cluster)
    [[ "${ROLE}" == "first" ]] && output_join_info

    echo ""
    log_ok "K3s HA control plane (${ROLE}) installed. Log: ${LOG_FILE}"
    log_info ""

    if [[ "${ROLE}" == "first" ]]; then
        log_info "Next steps:"
        log_info "  1. Run install-k3s-ha-server.sh --role additional on remaining control planes"
        log_info "  2. Run prepare-node.sh + install-k3s-agent.sh on each worker"
        log_info "  3. Run install-cilium.sh on one control plane after all nodes joined"
        log_info "  4. Run validate-cluster.sh to verify the full stack"
    else
        log_info "Next steps:"
        log_info "  1. Add more control planes or workers (see first CP output for token)"
        log_info "  2. Run install-cilium.sh on first CP when all nodes have joined"
    fi
}

main "$@"
