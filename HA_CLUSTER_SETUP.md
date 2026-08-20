# K3s HA Cluster — Complete Installation Guide

Fully automated, air-gap installation of a **production-grade K3s HA cluster** with:
- **1 etcd** data-store node
- **2 K3s control planes** (HA, no single point of failure)
- **3 K3s worker nodes**
- **Cilium CNI** with WireGuard transparent encryption
- **nginx TCP load balancer** in front of the control planes

All steps use the automation scripts in `scripts/`. No manual etcd or K3s setup required.

---

## Table of Contents

### Option A — External etcd (Dedicated etcd Node)
1. [Architecture](#architecture)
2. [Pre-Requirements](#pre-requirements)
3. [Port & Firewall Requirements](#port--firewall-requirements)
4. [Phase 0 — Prepare Offline Bundle](#phase-0--prepare-offline-bundle-internet-machine)
5. [Phase 1 — Distribute Bundle to VMs](#phase-1--distribute-bundle-to-all-vms)
6. [Phase 2 — Prepare All Nodes](#phase-2--prepare-all-nodes)
7. [Phase 3 — Install etcd](#phase-3--install-etcd-data-store)
8. [Phase 4 — Install First Control Plane](#phase-4--install-first-control-plane-cp-1)
9. [Phase 5 — Install Second Control Plane](#phase-5--install-second-control-plane-cp-2)
10. [Phase 6 — Set Up Load Balancer](#phase-6--set-up-load-balancer-optional-but-recommended)
11. [Phase 7 — Install Worker Nodes](#phase-7--install-worker-nodes)
12. [Phase 8 — Install Cilium CNI + WireGuard](#phase-8--install-cilium-cni--wireguard)
13. [Phase 9 — Validate Cluster](#phase-9--validate-cluster)
14. [Expected State at Each Phase](#expected-state-at-each-phase)
15. [Troubleshooting](#troubleshooting)
16. [Rollback](#rollback)
17. [Quick Reference Card](#quick-reference-card)

### Option B — Embedded etcd (No Dedicated etcd Node)
18. [Option B: Architecture](#option-b-architecture)
19. [Option B: VM Requirements](#option-b-vm-requirements)
20. [Option B: Phase 1 — Distribute Bundle](#option-b-phase-1--distribute-bundle)
21. [Option B: Phase 2 — Prepare All Nodes](#option-b-phase-2--prepare-all-nodes)
22. [Option B: Phase 3 — Install First Control Plane](#option-b-phase-3--install-first-control-plane-cp-1-cluster-init)
23. [Option B: Phase 4 — Install Second Control Plane](#option-b-phase-4--install-second-control-plane-cp-2)
24. [Option B: Phase 5 — Set Up Load Balancer](#option-b-phase-5--set-up-load-balancer-optional)
25. [Option B: Phase 6 — Install Worker Nodes](#option-b-phase-6--install-worker-nodes)
26. [Option B: Phase 7 — Install Cilium CNI + WireGuard](#option-b-phase-7--install-cilium-cni--wireguard)
27. [Option B: Phase 8 — Validate Cluster](#option-b-phase-8--validate-cluster)
28. [Option B: Embedded etcd Backup and Restore](#option-b-embedded-etcd-backup-and-restore)
29. [Option B: Quick Reference Card](#option-b-quick-reference-card)

---

### Which Option Should I Use?

| | Option A — External etcd | Option B — Embedded etcd |
|---|---|---|
| **VMs required** | 7 (1 etcd + 2 CP + 1 LB + 3 workers) | 6 (2 CP + 1 LB + 3 workers) |
| **etcd management** | Separate, dedicated VM | Built into K3s control planes |
| **Complexity** | Higher — etcd managed separately | Lower — no etcd VM to maintain |
| **Backup** | Manual `etcdctl snapshot` | Built-in `k3s etcd-snapshot` |
| **Best for** | Production — full control over etcd | Labs / smaller deployments |
| **Failure isolation** | etcd and K3s failures are independent | etcd tied to CP node lifecycle |

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │     Internet-Connected Machine        │
                    │     prepare-offline-bundle.sh         │
                    │     → generates offline-bundle.tar.gz │
                    └──────────────────┬───────────────────┘
                                       │ scp / USB transfer
                                       ▼
          ┌────────────────────────────────────────────────────────────┐
          │                  Air-Gapped Network                         │
          │                  (e.g. UTM VMs / private LAN)              │
          │                                                            │
          │  ┌─────────────────────────────────────────────────┐      │
          │  │           nginx Load Balancer                    │      │
          │  │           192.168.64.20 (VIP)                   │      │
          │  │           Forwards :6443 → CP-1 or CP-2         │      │
          │  └──────────────────┬──────────────────────────────┘      │
          │                     │                                       │
          │         ┌───────────┴─────────────┐                        │
          │         │                         │                        │
          │  ┌──────▼──────┐         ┌────────▼────┐                  │
          │  │ Control      │         │ Control      │                  │
          │  │ Plane 1      │         │ Plane 2      │                  │
          │  │ 192.168.64.21│◄───────►│ 192.168.64.22│                  │
          │  │ k3s server   │         │ k3s server   │                  │
          │  └──────┬───────┘         └──────┬───────┘                 │
          │         │                        │                         │
          │         └────────────┬───────────┘                         │
          │                      │  etcd client (port 2379)           │
          │              ┌───────▼──────┐                              │
          │              │  etcd Node   │                              │
          │              │ 192.168.64.30│                              │
          │              │ Single data  │                              │
          │              │ store for    │                              │
          │              │ both CPs     │                              │
          │              └──────────────┘                              │
          │                                                            │
          │  ┌──────────────────────────────────────────────────┐     │
          │  │                  Worker Nodes                     │     │
          │  ├─────────────────────┬─────────────────────────── ┤     │
          │  │ worker-01           │ worker-02    │ worker-03   │     │
          │  │ 192.168.64.31      │ 192.168.64.32│192.168.64.33│     │
          │  │ k3s agent          │ k3s agent    │ k3s agent   │     │
          │  └─────────────────────┴─────────────────────────── ┘     │
          │                  ↑ All connect to load balancer VIP        │
          │                                                            │
          │  ══════════════ WireGuard Encrypted Overlay ═══════════   │
          │         Cilium CNI encrypts all pod-to-pod traffic         │
          └────────────────────────────────────────────────────────────┘
```

---

## Pre-Requirements

### VM Specifications

| VM | Hostname | IP | RAM | CPU | Disk | Role |
|----|----------|----|-----|-----|------|------|
| etcd | etcd-node | 192.168.64.30 | 2 GB | 2 | 20 GB | etcd data store |
| cp-1 | cp-1 | 192.168.64.21 | 4 GB | 4 | 30 GB | K3s control plane (first) |
| cp-2 | cp-2 | 192.168.64.22 | 4 GB | 4 | 30 GB | K3s control plane (additional) |
| lb | lb-node | 192.168.64.20 | 1 GB | 1 | 10 GB | nginx load balancer |
| worker-01 | worker-01 | 192.168.64.31 | 4 GB | 2 | 30 GB | K3s worker |
| worker-02 | worker-02 | 192.168.64.32 | 4 GB | 2 | 30 GB | K3s worker |
| worker-03 | worker-03 | 192.168.64.33 | 4 GB | 2 | 30 GB | K3s worker |

> **Total**: 7 VMs. The lb VM is optional but strongly recommended for true HA.

### Operating System Requirements (Each VM)

- **OS**: Ubuntu 24.04 LTS (Noble Numbat)
- **Kernel**: 6.x or later (required for eBPF + WireGuard)
- **Username**: `ubuntu` (scripts configure kubectl for this user automatically)
- **Swap**: Will be disabled by `prepare-node.sh`
- **Network**: All VMs on the same subnet, can reach each other

### Unique Hostnames (Critical)

Each VM **must** have a unique hostname. K3s uses hostname as the node name.

```bash
# Set on each VM before starting (replace with correct name)
sudo hostnamectl set-hostname etcd-node    # on etcd VM
sudo hostnamectl set-hostname cp-1         # on CP-1 VM
sudo hostnamectl set-hostname cp-2         # on CP-2 VM
sudo hostnamectl set-hostname lb-node      # on LB VM
sudo hostnamectl set-hostname worker-01    # on worker-01 VM
sudo hostnamectl set-hostname worker-02    # on worker-02 VM
sudo hostnamectl set-hostname worker-03    # on worker-03 VM

# Verify
hostname
```

### Offline Bundle

The offline bundle (`/opt/offline-bundle`) must be present on **all VMs except the load balancer**.
Generated by `prepare-offline-bundle.sh` on an internet-connected machine.

---

## Port & Firewall Requirements

### Open on All K3s Nodes (CPs + Workers)

| Port | Protocol | Description |
|------|----------|-------------|
| 6443 | TCP | K3s API server |
| 10250 | TCP | Kubelet API |
| 8472 | UDP | Cilium VXLAN tunnel |
| 51820 | UDP | WireGuard (Cilium encryption) |
| 4240 | TCP | Cilium health checks |
| 4244 | TCP | Hubble relay |

### Open on etcd Node

| Port | Protocol | Description |
|------|----------|-------------|
| 2379 | TCP | etcd client (K3s connects here) |
| 2380 | TCP | etcd peer (required for multi-node etcd) |

### Open on Load Balancer

| Port | Protocol | Description |
|------|----------|-------------|
| 6443 | TCP | K3s API proxy to control planes |

### For Ubuntu UFW (run on each VM if firewall is enabled)

```bash
# On control planes and workers:
sudo ufw allow 6443/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 8472/udp
sudo ufw allow 51820/udp
sudo ufw allow 4240/tcp
sudo ufw allow 4244/tcp

# On etcd node:
sudo ufw allow 2379/tcp
sudo ufw allow 2380/tcp

# On load balancer:
sudo ufw allow 6443/tcp
```

---

## Phase 0 — Prepare Offline Bundle (Internet Machine)

> Run this **once** on any machine with internet access.
> This generates `offline-bundle.tar.gz` containing all binaries, images, and Helm charts.

```bash
# On internet-connected machine
cd /path/to/k3s_cluster

# Full bundle (includes all container images — takes 10-20 minutes)
./prepare-offline-bundle.sh

# If you want to skip large Docker images (useful for testing):
./prepare-offline-bundle.sh --skip-images

# Result:
# ./offline-bundle/         — unpacked bundle
# ./offline-bundle.tar.gz   — compressed archive (~2-4 GB)
```

**What gets downloaded:**

| Component | Version | Included As |
|-----------|---------|-------------|
| K3s binary | v1.34.5+k3s1 | `binaries/k3s` |
| K3s airgap images | v1.34.5 | `images/k3s-airgap-images-arm64.tar.gz` |
| kubectl | v1.34.5 | `binaries/kubectl` |
| helm | v3.20.0 | `binaries/helm` |
| crictl | v1.35.0 | `binaries/crictl` |
| cilium CLI | v0.19.2 | `binaries/cilium` |
| etcd + etcdctl | v3.5.17 | `binaries/etcd`, `binaries/etcdctl` |
| Cilium Helm chart | 1.19.1 | `helm-charts/cilium-1.19.1.tgz` |
| Cilium images | 1.19.1 | `images/cilium-images.tar` |
| cert-manager images | v1.19.4 | `images/cert-manager-images.tar` |

---

## Phase 1 — Distribute Bundle to All VMs

> Transfer the bundle from the internet machine to every VM that needs it.
> **All VMs except the load balancer** need the bundle.

```bash
# On internet-connected machine — transfer to each VM:
scp ./offline-bundle.tar.gz ubuntu@192.168.64.30:/tmp/    # etcd
scp ./offline-bundle.tar.gz ubuntu@192.168.64.21:/tmp/    # cp-1
scp ./offline-bundle.tar.gz ubuntu@192.168.64.22:/tmp/    # cp-2
scp ./offline-bundle.tar.gz ubuntu@192.168.64.31:/tmp/    # worker-01
scp ./offline-bundle.tar.gz ubuntu@192.168.64.32:/tmp/    # worker-02
scp ./offline-bundle.tar.gz ubuntu@192.168.64.33:/tmp/    # worker-03
```

```bash
# On EACH VM (etcd, cp-1, cp-2, worker-01, worker-02, worker-03) — extract:
sudo mkdir -p /opt
sudo tar -xzf /tmp/offline-bundle.tar.gz -C /opt/

# Verify extraction
ls /opt/offline-bundle/
# Expected:
#   binaries/   helm-charts/   images/   manifests/   metadata/   checksums/   logs/
```

> Also transfer the scripts directory to each VM:

```bash
# On internet-connected machine
scp -r ./scripts ubuntu@192.168.64.30:/home/ubuntu/    # etcd (needs install-etcd.sh)
scp -r ./scripts ubuntu@192.168.64.21:/home/ubuntu/    # cp-1
scp -r ./scripts ubuntu@192.168.64.22:/home/ubuntu/    # cp-2
scp -r ./scripts ubuntu@192.168.64.31:/home/ubuntu/    # worker-01
scp -r ./scripts ubuntu@192.168.64.32:/home/ubuntu/    # worker-02
scp -r ./scripts ubuntu@192.168.64.33:/home/ubuntu/    # worker-03
```

---

## Phase 2 — Prepare All Nodes

> Run on **every VM** (etcd, cp-1, cp-2, worker-01, worker-02, worker-03).
> Sets up kernel modules, sysctl settings, swap disable, and system packages.

```bash
# SSH into each VM and run:
cd ~/scripts
sudo ./prepare-node.sh
```

**Expected output (each VM):**
```
  ┌───────────────────────────────────────────────┐
  │        K3s Node Preparation                   │
  └───────────────────────────────────────────────┘

══ [STEP] Checking System Requirements
  ✔ CPU cores: 4 (minimum: 2)
  ✔ RAM: 3.8 GB (minimum: 2 GB)
  ✔ Disk: 28 GB free (minimum: 10 GB)
  ✔ Kernel version: 6.8.0 (minimum: 6.x)

══ [STEP] Loading Kernel Modules
  ✔ veth
  ✔ wireguard
  ✔ xt_socket

══ [STEP] Applying Sysctl Settings
  ✔ net.ipv4.ip_forward = 1
  ✔ net.bridge.bridge-nf-call-iptables = 1
  ...

══ [STEP] Disabling Swap
  ✔ Swap disabled

[INFO] Node preparation complete ✔
```

**Run this on all 6 VMs before proceeding.**

---

## Phase 3 — Install etcd Data Store

> Run on the **etcd VM** (192.168.64.30) only.

```bash
# SSH into etcd VM
ssh ubuntu@192.168.64.30

cd ~/scripts

# Single-node etcd (standard setup)
sudo ./install-etcd.sh --node-ip 192.168.64.30
```

**What it does:**
- Creates `etcd` system user (restricted, no shell)
- Creates `/var/lib/etcd` and `/etc/etcd` directories
- Copies `etcd` + `etcdctl` from offline bundle
- Writes `/etc/etcd/etcd.conf` configuration
- Writes `/etc/systemd/system/etcd.service` systemd unit
- Starts etcd and waits for health
- Verifies read/write via `etcdctl`

**Expected final output:**
```
  ✔ etcd is healthy (10s)
  ✔ etcdctl confirmed endpoint healthy
  ✔ etcd read/write test passed

╔═══════════════════════════════════════════════════════════╗
║        etcd Ready — K3s HA Connection Information         ║
╚═══════════════════════════════════════════════════════════╝

  etcd endpoint (client):
  http://192.168.64.30:2379

  Use with install-k3s-ha-server.sh (first control plane):
  sudo ./install-k3s-ha-server.sh \
      --role first \
      --node-ip <CONTROL_PLANE_IP> \
      --datastore-endpoint http://192.168.64.30:2379
```

**Verify etcd is running:**
```bash
curl http://192.168.64.30:2379/health
# Expected: {"health":"true","reason":""}
```

---

### Multi-Node etcd Cluster (3 Nodes — Recommended for Production)

> The single-node etcd above is a single point of failure — if that VM goes
> down, the **entire** K3s cluster loses its datastore and stops functioning,
> regardless of how many control planes you have running. A 3-node etcd
> cluster tolerates one node failure with zero cluster downtime.

**Requirements:**
- **Always use an odd number of etcd nodes** (3, or 5 for larger clusters).
  etcd uses Raft consensus and needs a majority quorum to accept writes —
  2 nodes is *worse* than 1, since losing either one breaks the majority.
- Each node needs the offline bundle and open ports `2379` (client) and
  `2380` (peer, node-to-node only — see
  [Port & Firewall Requirements](#port--firewall-requirements)).

**Run on each of the 3 etcd VMs**, using the *same* `--initial-cluster`
value (all three peer URLs) on every node — only `--node-ip` and
`--node-name` change:

```bash
# On etcd-1 (192.168.64.30)
sudo ./install-etcd.sh --node-ip 192.168.64.30 --node-name etcd-1 \
  --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"

# On etcd-2 (192.168.64.31)
sudo ./install-etcd.sh --node-ip 192.168.64.31 --node-name etcd-2 \
  --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"

# On etcd-3 (192.168.64.32)
sudo ./install-etcd.sh --node-ip 192.168.64.32 --node-name etcd-3 \
  --initial-cluster "etcd-1=http://192.168.64.30:2380,etcd-2=http://192.168.64.31:2380,etcd-3=http://192.168.64.32:2380"
```

> Run all three install commands within a couple of minutes of each other —
> etcd's initial bootstrap expects the whole quorum to come up together. If
> a node lags too far behind or fails to join, wipe just that node
> (`sudo ./rollback.sh --etcd --force`) and re-run its install command.

**Verify the cluster formed correctly:**
```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=http://192.168.64.30:2379,http://192.168.64.31:2379,http://192.168.64.32:2379 \
  member list -w table
# All 3 members should show STATUS=started
```

**Use with `install-k3s-ha-server.sh`** — pass all three endpoints as a
comma-separated list to `--datastore-endpoint`. K3s's etcd client fails over
across whichever members are alive on its own; no separate load balancer is
needed for etcd traffic:

```bash
sudo ./install-k3s-ha-server.sh \
  --role first \
  --node-ip <CONTROL_PLANE_IP> \
  --datastore-endpoint http://192.168.64.30:2379,http://192.168.64.31:2379,http://192.168.64.32:2379
```

**Failure behavior:** with 3 nodes, any single etcd VM can go down and the
cluster keeps serving reads and writes — Raft still has a 2-of-3 majority.
Losing 2 of 3 takes the datastore down (same as losing the only node in a
single-node setup), since there's no longer a quorum.

---

## Phase 4 — Install First Control Plane (cp-1)

> Run on **cp-1** (192.168.64.21) only.

```bash
# SSH into cp-1
ssh ubuntu@192.168.64.21

cd ~/scripts

sudo ./install-k3s-ha-server.sh \
  --role first \
  --node-ip 192.168.64.21 \
  --node-name cp-1 \
  --datastore-endpoint http://192.168.64.30:2379 \
  --load-balancer-ip 192.168.64.20
```

> `--load-balancer-ip` adds the LB VIP to TLS SANs — skip this if you are not using a load balancer.

**What it does:**
- Verifies etcd is reachable at `192.168.64.30:2379`
- Copies K3s binary + airgap images from bundle
- Runs `install.sh` with:
  - `--flannel-backend=none` (Cilium will handle networking)
  - `--disable-kube-proxy` (Cilium replaces kube-proxy)
  - `--disable=traefik,servicelb`
  - `K3S_DATASTORE_ENDPOINT=http://192.168.64.30:2379`
- Waits for API server to become healthy
- Configures `kubectl` for both `root` and `ubuntu` users
- Outputs the cluster join token

**Expected final output:**
```
  ✔ K3s API server healthy via https://192.168.64.21:6443/healthz

╔════════════════════════════════════════════════════════╗
║        HA Cluster Join Information                     ║
╚════════════════════════════════════════════════════════╝

  Cluster token:
  K10407c179d...::server:abcdef1234

  Add another control plane:
  sudo ./install-k3s-ha-server.sh \
      --role additional \
      --node-ip <NEW_CP_IP> \
      --datastore-endpoint http://192.168.64.30:2379 \
      --cluster-token 'K10407c179d...::server:abcdef1234'

  Add worker nodes:
  sudo ./install-k3s-agent.sh \
      --server-ip 192.168.64.20 \
      --token 'K10407c179d...::server:abcdef1234' \
      --node-name worker-01
```

**Save the token** — you will need it for cp-2 and all workers.

```bash
# Retrieve token at any time from cp-1:
sudo cat /var/log/k3s-install/node-token.txt
```

**Verify cp-1 is in the cluster:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
# NAME   STATUS     ROLES                  AGE
# cp-1   NotReady   control-plane,master   1m
# (NotReady is normal — Cilium not yet installed)
```

---

## Phase 5 — Install Second Control Plane (cp-2)

> Run on **cp-2** (192.168.64.22) only.
> You need the token from Phase 4.

```bash
# SSH into cp-2
ssh ubuntu@192.168.64.22

cd ~/scripts

# Replace TOKEN with the value from Phase 4
TOKEN="K10407c179d...::server:abcdef1234"

sudo ./install-k3s-ha-server.sh \
  --role additional \
  --node-ip 192.168.64.22 \
  --node-name cp-2 \
  --datastore-endpoint http://192.168.64.30:2379 \
  --cluster-token "${TOKEN}" \
  --load-balancer-ip 192.168.64.20
```

**Expected final output:**
```
  ✔ K3s API server healthy via https://192.168.64.22:6443/healthz
  ✔ Node 'cp-2' found in cluster (status: NotReady)

  Current control plane nodes:
  NAME   STATUS     ROLES                  AGE
  cp-1   NotReady   control-plane,master   5m
  cp-2   NotReady   control-plane,master   30s
```

> **Note:** while cp-2 joins, `systemctl status k3s` on cp-1 may briefly show
> `activating (auto-restart)` for a few seconds. This is cp-1 reconciling its
> peer/tunnel connections to the new control plane, not a failure — it
> settles into `active (running)` on its own within seconds.

**Verify both control planes on cp-1:**
```bash
# On cp-1
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -l node-role.kubernetes.io/control-plane
# Both cp-1 and cp-2 should appear
```

---

## Phase 6 — Set Up Load Balancer (Optional but Recommended)

> Run on the **lb VM** (192.168.64.20).
> Routes all `kubectl` and worker connections to whichever CP is available.

```bash
# SSH into lb VM
ssh ubuntu@192.168.64.20

# Install nginx (requires internet or pre-downloaded deb)
# If using ubuntu deb packages from bundle:
sudo dpkg -i /opt/offline-bundle/packages/nginx*.deb 2>/dev/null || \
    sudo apt-get install -y nginx
```

```bash
# Write nginx stream config for TCP load balancing
sudo tee /etc/nginx/nginx.conf > /dev/null <<'NGINX_EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    upstream k3s_api_servers {
        server 192.168.64.21:6443;
        server 192.168.64.22:6443;
    }

    server {
        listen 6443;
        proxy_pass k3s_api_servers;
        proxy_connect_timeout 5s;
        proxy_timeout 30s;
    }
}
NGINX_EOF
```

```bash
# Enable and start nginx
sudo systemctl enable nginx
sudo systemctl restart nginx
sudo systemctl is-active nginx
# active

# Test: from cp-1, verify LB forwards to API
curl -sk https://192.168.64.20:6443/healthz
# ok
```

> If you skipped the LB, use `192.168.64.21` (cp-1 IP) as the server IP in remaining steps.

---

## Phase 7 — Install Worker Nodes

> Run on **each worker** (worker-01, worker-02, worker-03).
> All 3 can be run **in parallel** (different SSH sessions).

```bash
# Retrieve token from cp-1 (if you don't have it)
TOKEN=$(sudo cat /var/log/k3s-install/node-token.txt)
# Or from cp-1: sudo cat /var/lib/rancher/k3s/server/node-token
```

### worker-01 (192.168.64.31)

```bash
# SSH into worker-01
ssh ubuntu@192.168.64.31

cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-01
```

### worker-02 (192.168.64.32)

```bash
# SSH into worker-02
ssh ubuntu@192.168.64.32

cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-02
```

### worker-03 (192.168.64.33)

```bash
# SSH into worker-03
ssh ubuntu@192.168.64.33

cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-03
```

> Use `--server-ip 192.168.64.21` instead of `.20` if you skipped the load balancer.

**Expected output per worker:**
```
  ✔ Ping to 192.168.64.20 OK
  ✔ TCP port 6443 reachable on 192.168.64.20
  ✔ Proceeding with node name: worker-01
  ✔ k3s-agent.service: Active (running)
```

**Verify all 5 nodes on cp-1:**
```bash
# On cp-1
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide

# Expected (Cilium not yet installed — NotReady is normal):
# NAME        STATUS     ROLES                  AGE
# cp-1        NotReady   control-plane,master   15m
# cp-2        NotReady   control-plane,master   10m
# worker-01   NotReady   <none>                 3m
# worker-02   NotReady   <none>                 2m
# worker-03   NotReady   <none>                 1m
```

---

## Phase 8 — Install Cilium CNI + WireGuard

> Run **once** from **cp-1**.
> Wait until all 5 nodes appear in `kubectl get nodes` before running this.

```bash
# On cp-1
ssh ubuntu@192.168.64.21

cd ~/scripts

sudo ./install-cilium.sh --server-ip 192.168.64.21
```

> Use the CP1 IP (not the LB) for `--server-ip` — this is the `k8sServiceHost` Cilium uses internally.

**What it does:**
- Cleans up any stuck namespaces (`cilium-secrets` Terminating etc.)
- Loads Cilium images into containerd (`ctr images import`)
- Runs `helm install cilium` from the offline chart with:
  - WireGuard encryption enabled
  - `persistentKeepalive: 25s`
  - `pullPolicy: IfNotPresent`
  - Hubble observability enabled
- Waits for Cilium DaemonSet pods on all nodes (up to 10 minutes)
- Verifies WireGuard interface (`cilium_wg0`) is created
- Waits for all nodes to transition to `Ready`

**Expected final output:**
```
  ✔ Cilium DaemonSet: 5/5 pods running
  ✔ WireGuard interface cilium_wg0 is up
  ✔ All 5 nodes are Ready
```

**Verify Cilium on all nodes:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# All nodes Ready:
kubectl get nodes
# NAME        STATUS   ROLES                  AGE
# cp-1        Ready    control-plane,master   25m
# cp-2        Ready    control-plane,master   20m
# worker-01   Ready    <none>                 10m
# worker-02   Ready    <none>                 9m
# worker-03   Ready    <none>                 8m

# Cilium pods running on all nodes:
kubectl get pod -n kube-system -l k8s-app=cilium -o wide
# One cilium pod per node (5 total)

# WireGuard active:
sudo ip link show cilium_wg0
sudo wg show cilium_wg0
# Shows peers for each node
```

---

## Phase 9 — Validate Cluster

> Run **from cp-1** after all nodes are `Ready`.

```bash
# On cp-1
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

cd ~/scripts

# Full validation (includes 130-test Cilium connectivity suite — ~5 min)
sudo ./validate-cluster.sh --server-ip 192.168.64.21

# Skip long connectivity test (faster, ~1 min)
sudo ./validate-cluster.sh --server-ip 192.168.64.21 --skip-connectivity-test
```

**What it checks:**

| Check | Description |
|-------|-------------|
| K3s service | `systemctl is-active k3s` |
| API server health | `/readyz` and `/healthz` endpoints |
| Node count | All nodes registered and Ready |
| System pods | kube-system pods not crashing |
| Cilium DaemonSet | All pods Running |
| Cilium operator | Deployment healthy |
| WireGuard interface | `cilium_wg0` exists on all nodes |
| WireGuard peers | Active peers between all nodes |
| Pod DNS | CoreDNS resolving correctly |
| Pod connectivity | Test pods can communicate cross-node |
| Cilium connectivity | 130 network policy + L4/L7 tests |

**Expected output:**
```
  ✔ 13 PASS checks
  ✗  0 FAIL checks

Cluster is healthy ✔
```

---

## Expected State at Each Phase

| Phase | cp-1 | cp-2 | workers | etcd | Cilium | Nodes Ready |
|-------|------|------|---------|------|--------|-------------|
| After Phase 3 | ✗ | ✗ | ✗ | ✔ Running | ✗ | 0/5 |
| After Phase 4 | ✔ Running | ✗ | ✗ | ✔ | ✗ | 0/5 |
| After Phase 5 | ✔ | ✔ Running | ✗ | ✔ | ✗ | 0/5 |
| After Phase 6 | ✔ | ✔ | ✗ | ✔ | ✗ | 0/5 |
| After Phase 7 | ✔ | ✔ | ✔ Running | ✔ | ✗ | 0/5 |
| After Phase 8 | ✔ | ✔ | ✔ | ✔ | ✔ Running | **5/5** ✔ |
| After Phase 9 | ✔ | ✔ | ✔ | ✔ | ✔ | **5/5** ✔ |

> **NotReady is normal** until Cilium is installed (Phase 8). All nodes need a CNI to become Ready.

---

## Troubleshooting

### etcd won't start

```bash
# On etcd VM — check service status
sudo systemctl status etcd
sudo journalctl -u etcd -n 50 --no-pager

# Common causes:
# 1. Data directory permissions
sudo chown -R etcd:etcd /var/lib/etcd

# 2. Port already in use
sudo ss -tlnp | grep 2379

# 3. Stale data from previous run — use rollback.sh, not a hand-rolled rm -rf.
#    (see "etcd data wipe silently does nothing" below for why)
sudo ./rollback.sh --etcd --force
```

### etcd data wipe silently does nothing

```bash
# DO NOT run this directly in an interactive shell:
sudo rm -rf /var/lib/etcd/*        # ← looks fine, but is a no-op in practice

# Why: `/var/lib/etcd` is 750 etcd:etcd. Bash expands the `*` glob using YOUR
# (non-root) shell permissions BEFORE sudo elevates the command. If your user
# can't list the directory, the glob matches nothing and bash passes the
# literal string "/var/lib/etcd/*" to rm — which finds no such file and does
# nothing. etcd then restarts and reloads its untouched data, making a wipe
# look like it "didn't work" for no obvious reason.

# Fix — either use the automated rollback (preferred, runs fully as root):
sudo ./rollback.sh --etcd --force

# ...or if wiping by hand, run the glob expansion inside a root shell:
sudo systemctl stop etcd
sudo sh -c 'rm -rf /var/lib/etcd/*'
sudo chown -R etcd:etcd /var/lib/etcd
sudo chmod 750 /var/lib/etcd
sudo systemctl start etcd

# Verify it's actually empty afterward (also needs a root shell, same reason):
sudo sh -c 'ls -la /var/lib/etcd/member/wal/' 2>&1
ETCDCTL_API=3 etcdctl --endpoints=http://<etcd-ip>:2379 get /registry --prefix --keys-only
# ↑ should print nothing
```

### cp-2 fails to connect to etcd

```bash
# On cp-2 — test etcd reachability
curl http://192.168.64.30:2379/health

# If not reachable from cp-2, check network:
ping 192.168.64.30
nc -zv 192.168.64.30 2379

# On etcd VM — check it is listening on 0.0.0.0 (not just localhost)
sudo ss -tlnp | grep 2379
# Should show: *:2379 (0.0.0.0)
```

### K3s server crash-loops with SIGSEGV

```bash
sudo systemctl status k3s --no-pager
# Active: activating (auto-restart) (Result: exit-code)
# Main PID: ... status=11/SEGV

sudo journalctl -u k3s --no-pager -n 50
# k3s.service: Main process exited, code=killed, status=11/SEGV
# k3s.service: Scheduled restart job, restart counter is at N.
```

**This is almost never the binary, the kernel, or hardware.** Before assuming
either of those, compare the bundle's `k3s` binary checksum against a known-
good copy (`sha256sum /opt/offline-bundle/binaries/k3s`) — if it matches,
corruption is ruled out.

The actual cause is nearly always **stale/corrupted local state** left behind
in `/var/lib/rancher/k3s` from an earlier crashed or interrupted install —
partially-written certs, TLS secrets, or bootstrap data from a previous
attempt that never finished cleanly. A completely clean, isolated test run
(fresh `--data-dir`, no reuse of `/var/lib/rancher/k3s`) will succeed even
when the real systemd-managed install keeps segfaulting, which confirms it.

**Fix:**
```bash
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
sudo rm -f /var/log/k3s-install/.ha-server-steps
sudo ./install-k3s-ha-server.sh --role <first|additional> ...   # re-run with original flags
```

### "bootstrap data already found and encrypted with different token"

```bash
sudo journalctl -u k3s --no-pager -n 20
# level=fatal msg="Error: starting kubernetes: failed to start cluster:
#   bootstrap data already found and encrypted with different token"
```

This is a **clean, expected failure**, not a crash — k3s detected that the
etcd datastore already holds bootstrap data (CA certs, cluster secrets)
encrypted with a token from a *different* install attempt (e.g. a previous
test run, or a `--role first` retry after etcd wasn't actually wiped — see
"etcd data wipe silently does nothing" above). It refuses to proceed rather
than risk corrupting existing cluster data.

**Fix:** the datastore needs a real wipe, not just a k3s-side reset:
```bash
# On the etcd node
sudo ./rollback.sh --etcd --force

# On the control plane node
sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
sudo rm -f /var/log/k3s-install/.ha-server-steps
sudo ./install-k3s-ha-server.sh --role first ...
```

### cp-2 token rejected

```bash
# Get fresh token from cp-1
sudo cat /var/lib/rancher/k3s/server/node-token

# Retry install with correct token:
sudo sed -i '/^ha-server-install$/d' /var/log/k3s-install/.ha-server-steps
sudo ./install-k3s-ha-server.sh --role additional \
  --node-ip 192.168.64.22 \
  --datastore-endpoint http://192.168.64.30:2379 \
  --cluster-token '<CORRECT_TOKEN>'
```

### Worker stuck connecting to server

```bash
# On worker VM — check connectivity
ping 192.168.64.20         # load balancer
nc -zv 192.168.64.20 6443  # API port via LB

# If LB unreachable, use direct CP-1 IP:
sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.21 \
  --token "${TOKEN}" \
  --node-name worker-01

# Check k3s-agent logs:
sudo journalctl -u k3s-agent -n 50 --no-pager
```

### Duplicate node name conflict

```bash
# On cp-1 — check existing nodes
kubectl get nodes

# If worker-01 already exists (from failed install), delete it:
kubectl delete node worker-01

# Then re-run agent install on the worker
```

### Cilium pods ErrImageNeverPull

```bash
# Images not loaded into containerd — load them manually:
sudo ctr --namespace k8s.io images import \
  /opt/offline-bundle/images/cilium-images.tar

# Verify images are loaded:
sudo ctr --namespace k8s.io images list | grep cilium

# Delete stuck pods to force re-creation:
kubectl delete pod -n kube-system -l k8s-app=cilium
kubectl delete pod -n kube-system -l app.kubernetes.io/name=cilium-operator
```

### cilium-secrets namespace stuck in Terminating

```bash
# The install-cilium.sh script handles this automatically.
# If you need to do it manually:
kubectl get namespace cilium-secrets -o json \
  | sed 's/"finalizers": \[.*\]/"finalizers": []/' \
  | kubectl replace --raw "/api/v1/namespaces/cilium-secrets/finalize" -f -
```

### Nodes still NotReady after Cilium install

```bash
# Check Cilium pod status:
kubectl get pod -n kube-system -l k8s-app=cilium -o wide

# Check if WireGuard is loaded:
lsmod | grep wireguard
# If empty: sudo modprobe wireguard

# Restart Cilium pods:
kubectl rollout restart daemonset cilium -n kube-system
```

### K3s API health check failing in validate-cluster.sh

```bash
# This is often transient (supervisor tunnel switches IPs during startup)
# The validation script retries automatically.
# Manually verify:
curl -sk https://127.0.0.1:6443/readyz
curl -sk https://192.168.64.21:6443/healthz
```

---

## Rollback

The `rollback.sh` script provides **fully automated cleanup** with role-specific flags. All flags can be combined for comprehensive cleanup.

### Flag Reference

| Flag | Purpose | Best Used On |
|------|---------|--------------|
| `--agent` | Remove k3s-agent service + binaries | Worker nodes only |
| `--server` | Remove k3s-server service + binaries | Control plane nodes only |
| `--etcd` | Remove etcd service + data + binaries | etcd node only |
| `--prepare` | Remove node prep (hostname validation state, container images) | Before clean reinstall |
| `--all` | Remove everything above + wipe `/var/log/k3s-install/` completely | For complete fresh start testing |
| `--force` | Skip confirmation prompts (use only in automation) | CI/CD or scripted rollback |

### Clean Slate Pattern

For testing from scratch on the **same VMs**, always use `--prepare --all`:

```bash
sudo ./rollback.sh --<role> --prepare --all
```

This removes:
- K3s service and binaries
- Container images and runtime state
- Installation tracking files and logs
- Hostname validation state (allows reinstall with same or different hostname)
- KUBECONFIG environment variables from shell configs

---

### Scenario 1: Rollback a Single Worker Node

To remove K3s agent and prepare for reinstall:

```bash
# On worker-01 (or worker-02, worker-03)
ssh ubuntu@192.168.64.31
cd ~/scripts

# Clean removal + prepare for fresh install
sudo ./rollback.sh --agent --prepare --all
```

**What gets removed:**
- k3s-agent service and binary
- Container images and containerd state
- Installation logs and step markers
- KUBECONFIG references from shell configs

**Result:** Node is back to base OS state. Can be reinstalled immediately.

---

### Scenario 2: Rollback a Control Plane Node

To remove K3s server and prepare for reinstall:

```bash
# On cp-1 or cp-2
ssh ubuntu@192.168.64.21  # or .22 for cp-2
cd ~/scripts

# Clean removal + prepare for fresh install
sudo ./rollback.sh --server --prepare --all
```

**What gets removed:**
- k3s-server service, binaries, and kubeconfig
- etcd data and snapshots (K3s-embedded SQLite for single-CP; not applicable for HA)
- Container images and containerd state
- Installation logs and step markers
- KUBECONFIG from `/etc/rancher/k3s/`, shell configs, and environment files

**Result:** Control plane node reverted to base OS. Can be reinstalled immediately.

**⚠️ Important for HA clusters:**
- Rollback cp-1 **only after** rolling back cp-2 and all workers
- External etcd cluster remains running (can survive CP resets)

---

### Scenario 3: Rollback etcd Node

To remove etcd service, data, and binaries:

```bash
# On etcd VM
ssh ubuntu@192.168.64.30
cd ~/scripts

# Automated etcd cleanup
sudo ./rollback.sh --etcd --all
```

**What gets removed:**
- etcd service and systemd unit
- etcd and etcdctl binaries
- etcd data directory (`/var/lib/etcd/`)
- etcd configuration directory (`/etc/etcd/`)
- etcd system user
- Installation logs and step markers

**Result:** etcd completely removed. Can be reinstalled immediately.

**⚠️ Warning:** This is **destructive** — all cluster state stored in etcd is lost. Only do this if:
- Testing cluster bootstrap repeatedly on same VMs
- You have K3s backups, or
- This is a non-production lab environment

---

### Scenario 4: Complete HA Cluster Clean Slate (All 7 VMs)

For testing the entire HA setup from scratch, rollback in this **reverse-dependency order**:

#### Step 1: Rollback all workers (parallel safe — 3-5 min)

```bash
# Run on worker-01, worker-02, worker-03 (all at once in separate SSH sessions)
ssh ubuntu@192.168.64.31 'cd ~/scripts && sudo ./rollback.sh --agent --prepare --all'
ssh ubuntu@192.168.64.32 'cd ~/scripts && sudo ./rollback.sh --agent --prepare --all'
ssh ubuntu@192.168.64.33 'cd ~/scripts && sudo ./rollback.sh --agent --prepare --all'
```

#### Step 2: Rollback cp-2 (single node — 2-3 min)

```bash
# Must be done before cp-1 if using load balancer
ssh ubuntu@192.168.64.22 'cd ~/scripts && sudo ./rollback.sh --server --prepare --all'
```

#### Step 3: Rollback cp-1 (single node — 2-3 min)

```bash
# Last control plane — cluster will be down after this
ssh ubuntu@192.168.64.21 'cd ~/scripts && sudo ./rollback.sh --server --prepare --all'
```

#### Step 4: Rollback etcd (single node — 1-2 min)

```bash
# Last — destroys all cluster state
ssh ubuntu@192.168.64.30 'cd ~/scripts && sudo ./rollback.sh --etcd --all'
```

#### Step 5: Optional — Rollback load balancer

If testing the full setup including nginx LB:

```bash
# On lb VM
ssh ubuntu@192.168.64.20

sudo systemctl stop nginx
sudo systemctl disable nginx
sudo rm -f /etc/nginx/nginx.conf

# Restore original nginx config (or skip if LB isn't part of your testing)
sudo apt-get install --reinstall nginx -y
```

**Total time:** ~10-15 min for all 7 nodes
**Result:** All VMs back to base OS. Cluster completely gone. Ready for fresh install.

---

### Scenario 5: Partial Rollback During Installation Failure

If installation fails on a node and you want to retry on the **same node** without fully rolling back others:

```bash
# On the problematic node (e.g., worker-03 failed during Cilium install)
ssh ubuntu@192.168.64.33
cd ~/scripts

# Remove just that node's K3s, keep step tracking for troubleshooting
sudo ./rollback.sh --agent --prepare

# Don't use --all here — you want to keep logs for debugging
# Review logs:
tail -50 /var/log/k3s-install/agent-install.log

# Once debugged, full clean:
sudo ./rollback.sh --agent --prepare --all

# Reinstall:
sudo ./install-k3s-agent.sh --server-ip 192.168.64.20 --token "${TOKEN}" --node-name worker-03
```

---

### Verification After Rollback

After rolling back a node, verify it's truly clean:

```bash
# On the rolled-back node
systemctl status k3s || echo "✔ k3s-server removed"
systemctl status k3s-agent || echo "✔ k3s-agent removed"
systemctl status etcd || echo "✔ etcd removed"

# Check no images remain
ctr --address /run/k3s/containerd/containerd.sock images list 2>/dev/null | wc -l
# Should output: 0 or "ctr: not found" (both OK)

# Check logs directory
ls -la /var/log/k3s-install/ 2>/dev/null || echo "✔ Logs cleaned"

# Check kubeconfig gone
ls -la /etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "✔ kubeconfig removed"

# Check kubectl env cleaned from shell configs
grep KUBECONFIG ~/.bashrc ~/.profile /etc/environment /etc/profile.d/* 2>/dev/null || echo "✔ KUBECONFIG env cleaned"
```

All checks should show "✔ removed" or "not found".

---

## etcd Backup and Restore

### Backup (run on etcd VM — schedule daily via cron)

```bash
# On etcd VM
BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/etcd"

sudo mkdir -p "${BACKUP_DIR}"

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=http://127.0.0.1:2379 \
  snapshot save "${BACKUP_DIR}/etcd-snapshot-${BACKUP_DATE}.db"

echo "Backup saved: ${BACKUP_DIR}/etcd-snapshot-${BACKUP_DATE}.db"

# Verify backup:
sudo ETCDCTL_API=3 etcdctl snapshot status \
  "${BACKUP_DIR}/etcd-snapshot-${BACKUP_DATE}.db" \
  --write-out=table
```

### Restore etcd from snapshot

```bash
# On etcd VM — ONLY if data is corrupt or lost
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd/*

sudo ETCDCTL_API=3 etcdctl snapshot restore \
  /var/backups/etcd/etcd-snapshot-20260308.db \
  --data-dir=/var/lib/etcd \
  --name=etcd-node \
  --initial-cluster="etcd-node=http://192.168.64.30:2380" \
  --initial-advertise-peer-urls=http://192.168.64.30:2380

sudo chown -R etcd:etcd /var/lib/etcd
sudo systemctl start etcd

# Verify:
curl http://127.0.0.1:2379/health
```

---

## Installation Timeline

| Phase | Task | Duration |
|-------|------|----------|
| 0 | prepare-offline-bundle.sh | 10–20 min (internet) |
| 1 | Transfer + extract bundle on 6 VMs | 5–10 min |
| 2 | prepare-node.sh on 6 VMs (parallelisable) | 5 min |
| 3 | install-etcd.sh on etcd VM | 2 min |
| 4 | install-k3s-ha-server.sh --role first | 5–8 min |
| 5 | install-k3s-ha-server.sh --role additional | 5–8 min |
| 6 | nginx LB setup | 5 min |
| 7 | install-k3s-agent.sh × 3 (parallelisable) | 5–8 min |
| 8 | install-cilium.sh | 5–10 min |
| 9 | validate-cluster.sh | 2–7 min |
| **Total** | | **~55–85 minutes** |

---

## Production Checklist

### Pre-Installation
- [ ] All VMs have unique hostnames (not "ubuntu")
- [ ] All VMs can ping each other
- [ ] Required ports open (see Port Requirements section)
- [ ] Offline bundle extracted at `/opt/offline-bundle` on all VMs
- [ ] Scripts directory at `~/scripts` on all VMs

### Installation
- [ ] `prepare-node.sh` completed on all 6 VMs (etcd, cp-1, cp-2, workers x3)
- [ ] etcd running and healthy: `curl http://192.168.64.30:2379/health`
- [ ] cp-1 running, token saved
- [ ] cp-2 running, joined via etcd
- [ ] nginx LB running, `curl -sk https://192.168.64.20:6443/healthz` returns `ok`
- [ ] All 3 workers joined (5 nodes visible in `kubectl get nodes`)
- [ ] Cilium installed, all nodes `Ready`
- [ ] WireGuard interface `cilium_wg0` up on all nodes

### Post-Installation
- [ ] `validate-cluster.sh` returns 0 FAIL checks
- [ ] etcd backup configured (cron job or periodic manual backup)
- [ ] Test control plane failover:
  - [ ] Stop k3s on cp-1 → verify cp-2 still serves API
  - [ ] Restart cp-1 → verify it rejoins cleanly
- [ ] Network policy default-deny applied to application namespaces

---

## Quick Reference Card

```bash
# ══════════════════════════════════════════
# INTERNET MACHINE
# ══════════════════════════════════════════
./prepare-offline-bundle.sh
scp offline-bundle.tar.gz ubuntu@192.168.64.{30,21,22,31,32,33}:/tmp/

# ══════════════════════════════════════════
# ALL VMs — extract bundle, set hostname
# ══════════════════════════════════════════
sudo tar -xzf /tmp/offline-bundle.tar.gz -C /opt/
sudo hostnamectl set-hostname <correct-name>
sudo ./scripts/prepare-node.sh

# ══════════════════════════════════════════
# etcd VM (192.168.64.30)
# ══════════════════════════════════════════
sudo ./scripts/install-etcd.sh --node-ip 192.168.64.30

# ══════════════════════════════════════════
# cp-1 (192.168.64.21)
# ══════════════════════════════════════════
sudo ./scripts/install-k3s-ha-server.sh \
  --role first \
  --node-ip 192.168.64.21 \
  --node-name cp-1 \
  --datastore-endpoint http://192.168.64.30:2379 \
  --load-balancer-ip 192.168.64.20

TOKEN=$(sudo cat /var/log/k3s-install/node-token.txt)
echo "Token: ${TOKEN}"

# ══════════════════════════════════════════
# cp-2 (192.168.64.22)
# ══════════════════════════════════════════
TOKEN="<paste from cp-1>"
sudo ./scripts/install-k3s-ha-server.sh \
  --role additional \
  --node-ip 192.168.64.22 \
  --node-name cp-2 \
  --datastore-endpoint http://192.168.64.30:2379 \
  --cluster-token "${TOKEN}" \
  --load-balancer-ip 192.168.64.20

# ══════════════════════════════════════════
# worker-01/02/03 (run on each)
# ══════════════════════════════════════════
TOKEN="<paste from cp-1>"
sudo ./scripts/install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-01        # change per node

# ══════════════════════════════════════════
# cp-1 — install Cilium (after all 5 nodes joined)
# ══════════════════════════════════════════
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes   # verify 5 nodes appear

sudo ./scripts/install-cilium.sh --server-ip 192.168.64.21

# ══════════════════════════════════════════
# cp-1 — validate
# ══════════════════════════════════════════
sudo ./scripts/validate-cluster.sh \
  --server-ip 192.168.64.21 \
  --skip-connectivity-test
```

---

---

# Option B — K3s HA Cluster with Embedded etcd (No Dedicated etcd Node)

> Use this setup when you want a simpler HA cluster without managing a separate etcd VM.
> K3s runs etcd **embedded inside each control plane node**. No external etcd required.

---

## Option B: Architecture

```
          ┌────────────────────────────────────────────────────────────┐
          │                  Air-Gapped Network                         │
          │                                                            │
          │  ┌─────────────────────────────────────────────────┐      │
          │  │           nginx Load Balancer (optional)         │      │
          │  │           192.168.64.20                         │      │
          │  │           Forwards :6443 → CP-1 or CP-2         │      │
          │  └──────────────────┬──────────────────────────────┘      │
          │                     │                                       │
          │         ┌───────────┴─────────────┐                        │
          │         │                         │                        │
          │  ┌──────▼──────────┐     ┌────────▼────────┐              │
          │  │  Control Plane 1 │◄───►│  Control Plane 2 │             │
          │  │  192.168.64.21  │     │  192.168.64.22  │              │
          │  │  k3s server     │     │  k3s server     │              │
          │  │  + etcd         │     │  + etcd         │              │
          │  │  (embedded)     │     │  (embedded)     │              │
          │  └──────┬──────────┘     └────────┬────────┘              │
          │         │                          │                        │
          │         └──────────┬───────────────┘                       │
          │                    │ etcd peer port 2380                   │
          │                    │ (CP nodes sync between themselves)    │
          │                                                            │
          │  ┌──────────────────────────────────────────────────┐     │
          │  │                  Worker Nodes                     │     │
          │  │ worker-01        worker-02        worker-03      │     │
          │  │ 192.168.64.31   192.168.64.32   192.168.64.33   │     │
          │  │ k3s agent       k3s agent       k3s agent       │     │
          │  └──────────────────────────────────────────────────┘     │
          │                                                            │
          │  ══════════════ WireGuard Encrypted Overlay ═══════════   │
          └────────────────────────────────────────────────────────────┘
```

**Key difference from Option A:** etcd is embedded inside each K3s control plane node.
No separate etcd VM is needed. The two CP nodes form an etcd cluster between themselves
using port `2380`. This saves 1 VM but ties etcd availability to the control planes.

---

## Option B: VM Requirements

| VM | Hostname | IP | RAM | CPU | Disk | Role |
|----|----------|----|-----|-----|------|------|
| cp-1 | cp-1 | 192.168.64.21 | 4 GB | 4 | 30 GB | K3s CP + embedded etcd (first) |
| cp-2 | cp-2 | 192.168.64.22 | 4 GB | 4 | 30 GB | K3s CP + embedded etcd (additional) |
| lb | lb-node | 192.168.64.20 | 1 GB | 1 | 10 GB | nginx load balancer (optional) |
| worker-01 | worker-01 | 192.168.64.31 | 4 GB | 2 | 30 GB | K3s worker |
| worker-02 | worker-02 | 192.168.64.32 | 4 GB | 2 | 30 GB | K3s worker |
| worker-03 | worker-03 | 192.168.64.33 | 4 GB | 2 | 30 GB | K3s worker |

> **Total: 6 VMs** (1 less than Option A — no dedicated etcd VM).
> CP nodes need slightly more disk (30 GB) because they store etcd data at
> `/var/lib/rancher/k3s/server/db/`.

### Additional Ports Required on Control Plane Nodes

| Port | Protocol | Description |
|------|----------|-------------|
| 2379 | TCP | etcd client (embedded — K3s internal only) |
| 2380 | TCP | etcd peer (CP-to-CP etcd replication) |

---

## Option B: Phase 1 — Distribute Bundle

Transfer bundle to **5 VMs** (no etcd VM):

```bash
# On internet-connected machine
scp ./offline-bundle.tar.gz ubuntu@192.168.64.21:/tmp/    # cp-1
scp ./offline-bundle.tar.gz ubuntu@192.168.64.22:/tmp/    # cp-2
scp ./offline-bundle.tar.gz ubuntu@192.168.64.31:/tmp/    # worker-01
scp ./offline-bundle.tar.gz ubuntu@192.168.64.32:/tmp/    # worker-02
scp ./offline-bundle.tar.gz ubuntu@192.168.64.33:/tmp/    # worker-03

# Extract on EACH VM:
sudo mkdir -p /opt
sudo tar -xzf /tmp/offline-bundle.tar.gz -C /opt/

# Transfer scripts to each VM:
scp -r ./scripts ubuntu@192.168.64.21:/home/ubuntu/
scp -r ./scripts ubuntu@192.168.64.22:/home/ubuntu/
scp -r ./scripts ubuntu@192.168.64.31:/home/ubuntu/
scp -r ./scripts ubuntu@192.168.64.32:/home/ubuntu/
scp -r ./scripts ubuntu@192.168.64.33:/home/ubuntu/
```

---

## Option B: Phase 2 — Prepare All Nodes

Run on **cp-1, cp-2, worker-01, worker-02, worker-03**:

```bash
cd ~/scripts
sudo ./prepare-node.sh
```

---

## Option B: Phase 3 — Install First Control Plane (cp-1, cluster-init)

> Run on **cp-1** (192.168.64.21) only.
> The `--cluster-init` flag tells K3s to bootstrap a new embedded etcd cluster.

```bash
ssh ubuntu@192.168.64.21

cd ~/scripts

sudo ./install-k3s-ha-server.sh \
  --role first \
  --node-ip 192.168.64.21 \
  --node-name cp-1 \
  --embedded-etcd \
  --load-balancer-ip 192.168.64.20
```

> Skip `--load-balancer-ip` if you are not using a load balancer.

**What it does (embedded etcd mode):**
- Copies K3s binary + airgap images from bundle
- Runs `install.sh` with `--cluster-init` (bootstraps embedded etcd cluster)
- No `--datastore-endpoint` — etcd runs internally at `/var/lib/rancher/k3s/server/db/`
- Waits for API server to become healthy
- Configures `kubectl` for `root` and `ubuntu` users
- Outputs cluster join token

**Expected final output:**
```
  ✔ K3s API server healthy via https://192.168.64.21:6443/healthz
  ✔ Embedded etcd cluster initialized

╔════════════════════════════════════════════════════════╗
║        HA Cluster Join Information                     ║
╚════════════════════════════════════════════════════════╝

  Cluster token:
  K10407c179d...::server:abcdef1234

  Add another control plane:
  sudo ./install-k3s-ha-server.sh \
      --role additional \
      --node-ip <NEW_CP_IP> \
      --embedded-etcd \
      --server-ip 192.168.64.21 \
      --cluster-token 'K10407c179d...::server:abcdef1234'

  Add worker nodes:
  sudo ./install-k3s-agent.sh \
      --server-ip 192.168.64.20 \
      --token 'K10407c179d...::server:abcdef1234' \
      --node-name worker-01
```

**Save the token:**
```bash
sudo cat /var/log/k3s-install/node-token.txt
```

**Verify embedded etcd is running:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Check K3s sees itself as an etcd member
sudo k3s etcd-snapshot ls
# Expected: lists any existing snapshots (empty on fresh install is OK)

# Verify API server is up
kubectl get nodes
# NAME   STATUS     ROLES                       AGE
# cp-1   NotReady   control-plane,etcd,master   1m
```

> Note the `etcd` role in the ROLES column — this confirms embedded etcd is active.

---

## Option B: Phase 4 — Install Second Control Plane (cp-2)

> Run on **cp-2** (192.168.64.22) only.
> Uses `--server` to join the embedded etcd cluster via cp-1's API server.

```bash
ssh ubuntu@192.168.64.22

cd ~/scripts

TOKEN="K10407c179d...::server:abcdef1234"   # from Phase 3

sudo ./install-k3s-ha-server.sh \
  --role additional \
  --node-ip 192.168.64.22 \
  --node-name cp-2 \
  --embedded-etcd \
  --server-ip 192.168.64.21 \
  --cluster-token "${TOKEN}" \
  --load-balancer-ip 192.168.64.20
```

**Expected final output:**
```
  ✔ K3s API server healthy via https://192.168.64.22:6443/healthz
  ✔ Node 'cp-2' joined embedded etcd cluster

  Current control plane nodes:
  NAME   STATUS     ROLES                       AGE
  cp-1   NotReady   control-plane,etcd,master   5m
  cp-2   NotReady   control-plane,etcd,master   30s
```

**Verify both CPs on cp-1:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -l node-role.kubernetes.io/control-plane
# Both cp-1 and cp-2 should show ROLES: control-plane,etcd,master
```

---

## Option B: Phase 5 — Set Up Load Balancer (Optional)

Same as Option A Phase 6 — nginx TCP load balancer forwarding port 6443 to cp-1 and cp-2.

```bash
ssh ubuntu@192.168.64.20

sudo apt-get install -y nginx   # or from offline bundle packages

sudo tee /etc/nginx/nginx.conf > /dev/null <<'NGINX_EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    upstream k3s_api_servers {
        server 192.168.64.21:6443;
        server 192.168.64.22:6443;
    }

    server {
        listen 6443;
        proxy_pass k3s_api_servers;
        proxy_connect_timeout 5s;
        proxy_timeout 30s;
    }
}
NGINX_EOF

sudo systemctl enable nginx
sudo systemctl restart nginx

# Verify:
curl -sk https://192.168.64.20:6443/healthz
# ok
```

---

## Option B: Phase 6 — Install Worker Nodes

Same as Option A Phase 7. Run on **each worker** (all 3 can run in parallel):

```bash
# Get token from cp-1 (if needed)
TOKEN=$(ssh ubuntu@192.168.64.21 'sudo cat /var/log/k3s-install/node-token.txt')
```

### worker-01 (192.168.64.31)

```bash
ssh ubuntu@192.168.64.31
cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-01
```

### worker-02 (192.168.64.32)

```bash
ssh ubuntu@192.168.64.32
cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-02
```

### worker-03 (192.168.64.33)

```bash
ssh ubuntu@192.168.64.33
cd ~/scripts

sudo ./install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-03
```

**Verify all 5 nodes on cp-1:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide
# NAME        STATUS     ROLES                       AGE
# cp-1        NotReady   control-plane,etcd,master   15m
# cp-2        NotReady   control-plane,etcd,master   10m
# worker-01   NotReady   <none>                      3m
# worker-02   NotReady   <none>                      2m
# worker-03   NotReady   <none>                      1m
```

---

## Option B: Phase 7 — Install Cilium CNI + WireGuard

Identical to Option A Phase 8. Run **once** from **cp-1** after all 5 nodes appear:

```bash
ssh ubuntu@192.168.64.21
cd ~/scripts

sudo ./install-cilium.sh --server-ip 192.168.64.21
```

**Expected final output:**
```
  ✔ Cilium DaemonSet: 5/5 pods running
  ✔ WireGuard interface cilium_wg0 is up
  ✔ All 5 nodes are Ready
```

---

## Option B: Phase 8 — Validate Cluster

```bash
ssh ubuntu@192.168.64.21
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

cd ~/scripts
sudo ./validate-cluster.sh --server-ip 192.168.64.21

# Expected:
#   ✔ 13 PASS checks
#   ✗  0 FAIL checks
```

---

## Option B: Expected State at Each Phase

| Phase | cp-1 | cp-2 | workers | etcd | Cilium | Nodes Ready |
|-------|------|------|---------|------|--------|-------------|
| After Phase 3 | ✔ Running + etcd | ✗ | ✗ | embedded in cp-1 | ✗ | 0/5 |
| After Phase 4 | ✔ | ✔ Running + etcd | ✗ | embedded in cp-1+cp-2 | ✗ | 0/5 |
| After Phase 5 | ✔ | ✔ | ✗ | ✔ | ✗ | 0/5 |
| After Phase 6 | ✔ | ✔ | ✔ Running | ✔ | ✗ | 0/5 |
| After Phase 7 | ✔ | ✔ | ✔ | ✔ | ✔ Running | **5/5** ✔ |
| After Phase 8 | ✔ | ✔ | ✔ | ✔ | ✔ | **5/5** ✔ |

---

## Option B: Embedded etcd Backup and Restore

K3s has built-in snapshot support — no external `etcdctl` needed.

### Take a Manual Snapshot (on cp-1)

```bash
# Create a named snapshot
sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)

# List all snapshots
sudo k3s etcd-snapshot ls
# NAME                              SIZE    CREATED
# pre-upgrade-20260417              2.1 MB  2026-04-17T10:00:00Z

# Snapshots are stored at:
ls /var/lib/rancher/k3s/server/db/snapshots/
```

### Schedule Automatic Snapshots

```bash
# Enable scheduled snapshots (every 6 hours, keep last 5)
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<'EOF'
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 5
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
EOF

sudo systemctl restart k3s
```

### Restore from Snapshot

> **Warning:** Restoring stops the cluster. Do this on cp-1 only.

```bash
# Stop K3s on ALL nodes first
# On workers:
sudo systemctl stop k3s-agent

# On cp-2:
sudo systemctl stop k3s

# On cp-1 — restore:
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/pre-upgrade-20260417

# Start cp-1:
sudo systemctl start k3s

# Start cp-2:
sudo systemctl start k3s

# Start workers:
sudo systemctl start k3s-agent
```

---

## Option B: Quick Reference Card

```bash
# ══════════════════════════════════════════
# INTERNET MACHINE
# ══════════════════════════════════════════
./prepare-offline-bundle.sh
scp offline-bundle.tar.gz ubuntu@192.168.64.{21,22,31,32,33}:/tmp/

# ══════════════════════════════════════════
# ALL VMs (cp-1, cp-2, workers) — extract + prepare
# ══════════════════════════════════════════
sudo tar -xzf /tmp/offline-bundle.tar.gz -C /opt/
sudo hostnamectl set-hostname <correct-name>
sudo bash ~/scripts/prepare-node.sh
sudo bash /opt/offline-bundle/manifests/load-images.sh

# ══════════════════════════════════════════
# cp-1 (192.168.64.21) — bootstrap embedded etcd cluster
# ══════════════════════════════════════════
sudo ./scripts/install-k3s-ha-server.sh \
  --role first \
  --node-ip 192.168.64.21 \
  --node-name cp-1 \
  --embedded-etcd \
  --load-balancer-ip 192.168.64.20

TOKEN=$(sudo cat /var/log/k3s-install/node-token.txt)
echo "Token: ${TOKEN}"

# ══════════════════════════════════════════
# cp-2 (192.168.64.22) — join embedded etcd cluster
# ══════════════════════════════════════════
TOKEN="<paste from cp-1>"
sudo ./scripts/install-k3s-ha-server.sh \
  --role additional \
  --node-ip 192.168.64.22 \
  --node-name cp-2 \
  --embedded-etcd \
  --server-ip 192.168.64.21 \
  --cluster-token "${TOKEN}" \
  --load-balancer-ip 192.168.64.20

# ══════════════════════════════════════════
# lb-node (192.168.64.20) — optional nginx LB
# ══════════════════════════════════════════
# (see Phase 5 for full nginx config)
sudo systemctl enable --now nginx

# ══════════════════════════════════════════
# worker-01/02/03 (run on each in parallel)
# ══════════════════════════════════════════
TOKEN="<paste from cp-1>"
sudo ./scripts/install-k3s-agent.sh \
  --server-ip 192.168.64.20 \
  --token "${TOKEN}" \
  --node-name worker-01        # change per node

# ══════════════════════════════════════════
# cp-1 — install Cilium (after all 5 nodes joined)
# ══════════════════════════════════════════
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes   # verify 5 nodes with role: control-plane,etcd,master

sudo ./scripts/install-cilium.sh --server-ip 192.168.64.21

# ══════════════════════════════════════════
# cp-1 — validate
# ══════════════════════════════════════════
sudo ./scripts/validate-cluster.sh \
  --server-ip 192.168.64.21 \
  --skip-connectivity-test

# ══════════════════════════════════════════
# Embedded etcd — snapshot commands
# ══════════════════════════════════════════
sudo k3s etcd-snapshot save --name manual-$(date +%Y%m%d)
sudo k3s etcd-snapshot ls
```
