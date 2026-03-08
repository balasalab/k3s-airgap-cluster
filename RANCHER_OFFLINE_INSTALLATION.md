# Rancher Server — Offline Installation Guide

Deploy **Rancher management server** on a standalone K3s cluster in an **air-gapped environment**.

- **Completely automated** via `install-rancher.sh`
- **Single VM** (separate from your HA K3s workload cluster)
- **Self-signed certificates** (private CA)
- **No internet required** (all images pre-downloaded)

## Table of Contents

1. [Architecture](#architecture)
2. [Pre-Requirements](#pre-requirements)
3. [Phase 0 — Prepare Offline Bundle](#phase-0--prepare-offline-bundle-internet-machine)
4. [Phase 1 — Transfer Bundle to Rancher VM](#phase-1--transfer-bundle-to-rancher-vm)
5. [Phase 2 — Run Installation Script](#phase-2--run-installation-script)
6. [Phase 3 — Access Rancher UI](#phase-3--access-rancher-ui)
7. [Phase 4 — Import HA K3s Cluster](#phase-4--import-ha-k3s-cluster)
8. [Rollback](#rollback)
9. [Troubleshooting](#troubleshooting)
10. [Maintenance](#maintenance)
11. [Quick Reference](#quick-reference)

---

## Architecture

```
┌─────────────────────────────────────────┐
│      Rancher Management Server          │
│      192.168.64.23 (Standalone VM)      │
│                                         │
│  K3s server (local only)                │
│  ├─ servicelb (LoadBalancer support)    │
│  ├─ cert-manager (certificate mgmt)     │
│  ├─ traefik (ingress/reverse proxy)     │
│  └─ rancher (management UI)             │
│                                         │
│  Access: https://rancher.192...sslip.io │
└─────────────────────────────────────────┘
              │ HTTPS (port 443)
              │ cattle-cluster-agent
              ▼
┌─────────────────────────────────────────┐
│    HA K3s Workload Cluster              │
│    (Can import multiple clusters)       │
│                                         │
│  cp-1: 192.168.64.17 (control plane)   │
│  cp-2: 192.168.64.18 (control plane)   │
│  workers: 192.168.64.19-21             │
│  etcd: 192.168.64.9 (data store)       │
│  CNI: Cilium + WireGuard               │
└─────────────────────────────────────────┘
```

---

## Pre-Requirements

### 1. Rancher VM Specifications

| Item | Requirement |
|------|-------------|
| OS | Ubuntu 22.04 LTS or similar |
| RAM | 4 GB minimum (8 GB recommended) |
| CPU | 2 cores minimum (4 recommended) |
| Disk | 30 GB minimum |
| IP Address | Static IP (e.g., 192.168.64.23) |
| Hostname | `rancher` (or unique name) |
| Network | Must reach your HA K3s cluster nodes |

### 2. Offline Bundle Requirements

The bundle must be created by `prepare-offline-bundle.sh` and contain:

| Component | Version |
|-----------|---------|
| K3s | v1.34.5+k3s1 |
| Rancher | 2.13.2 |
| cert-manager | v1.19.4 |
| Traefik | 39.0.0 |

---

## Phase 0 — Prepare Offline Bundle (Internet Machine)

Run on an **internet-connected machine** that has Docker, Helm, and curl installed:

```bash
cd /path/to/k3s_cluster

# Full bundle including Rancher components (default)
./prepare-offline-bundle.sh

# OR: skip Rancher if you only need the K3s workload cluster bundle
./prepare-offline-bundle.sh --skip-rancher

# OR: custom output directory
./prepare-offline-bundle.sh --output-dir /mnt/usb/k3s-bundle
```

**What gets downloaded** (with Rancher):

```
offline-bundle/
├── binaries/           k3s, kubectl, helm, cilium CLI, crictl, etcd, etcdctl, install.sh
├── images/
│   ├── k3s-airgap-images-arm64.tar.gz   (or amd64)
│   ├── cilium-images.tar
│   ├── cert-manager-images.tar
│   └── rancher-images.tar               ← Rancher + Traefik images (~1.6 GB)
├── helm-charts/
│   ├── cilium-1.19.1.tgz
│   ├── cert-manager-v1.19.4.tgz
│   ├── traefik-39.0.0.tgz               ← for Rancher ingress
│   └── rancher-2.13.2.tgz               ← Rancher management UI
├── packages/           Ubuntu .deb packages
├── manifests/          Configuration templates
├── checksums/          sha256sums.txt
└── metadata/           version-info.txt, architecture.txt
```

> **Note:** `rancher-images.tar` is ~1.6 GB. Total bundle size is approximately 3-4 GB. Ensure sufficient disk space.

**Expected duration:** 15-30 min (depends on internet speed)

---

## Phase 1 — Transfer Bundle to Rancher VM

```bash
# Option A: SCP over network
scp -r offline-bundle ubuntu@192.168.64.23:/tmp/
ssh ubuntu@192.168.64.23 "sudo mkdir -p /opt && sudo mv /tmp/offline-bundle /opt/"

# Verify structure on Rancher VM
ssh ubuntu@192.168.64.23
ls /opt/offline-bundle/
# Should show: binaries/ helm-charts/ images/ packages/ manifests/ checksums/ metadata/

# Option B: USB drive (strict airgap)
# 1. Copy offline-bundle/ to USB drive
# 2. Mount USB on Rancher VM
# 3. sudo cp -r /mnt/usb/offline-bundle /opt/
```

Also transfer the install and rollback scripts:

```bash
# From your dev machine
scp scripts/install-rancher.sh  ubuntu@192.168.64.23:~/k3s_setup/scripts/
scp scripts/rollback-rancher.sh ubuntu@192.168.64.23:~/k3s_setup/scripts/
```

---

## Phase 2 — Run Installation Script

```bash
# SSH into Rancher VM
ssh ubuntu@192.168.64.23

# Run the automated installer
sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23 \
  --rancher-hostname rancher \
  --bootstrap-password changeme
```

**Parameters:**

| Flag | Default | Description |
|------|---------|-------------|
| `--bundle-path` | `/opt/offline-bundle` | Path to offline bundle |
| `--rancher-ip` | `192.168.64.11` | IP address of Rancher VM |
| `--rancher-hostname` | `rancher` | Hostname prefix for sslip.io domain |
| `--bootstrap-password` | `changeme` | Initial admin password |

**What the script does automatically:**

1. Verifies all bundle files are present
2. Installs K3s with servicelb enabled (for LoadBalancer support) and Traefik disabled
3. Copies K3s binary, airgap images, and binaries (kubectl, helm, crictl)
4. Waits for K3s API to be ready
5. Configures kubectl for root user
6. **Adds `/etc/hosts` entry** for airgap DNS resolution (sslip.io needs internet DNS)
7. Loads all Rancher container images into K3s containerd
8. Installs cert-manager from local Helm chart
9. Installs Traefik ingress controller from local Helm chart
10. Generates self-signed Root CA + server certificate
11. Creates `rancher-tls` TLS secret in cattle-system namespace
12. Creates `tls-ca` CA secret in cattle-system namespace (required by Rancher)
13. Installs Rancher from local Helm chart
14. Waits for Rancher to be fully ready

**Expected output:**

```
  ┌─────────────────────────────────────────────────┐
  │ Rancher Server — Automated Offline Installation │
  └─────────────────────────────────────────────────┘

[INFO]  Configuration:
[INFO]    Bundle Path      : /opt/offline-bundle
[INFO]    Rancher IP       : 192.168.64.23
[INFO]    Rancher Domain   : rancher.192.168.64.23.sslip.io
[INFO]    Rancher Version  : 2.13.2

══ [STEP] Verifying Offline Bundle at /opt/offline-bundle
  ✔ binaries/k3s
  ✔ binaries/install.sh
  ✔ images/k3s-airgap-images-arm64.tar.gz
  ✔ binaries/kubectl
  ✔ binaries/helm
  ✔ binaries/crictl
  ✔ helm-charts/cert-manager-v1.19.4.tgz
  ✔ helm-charts/rancher-2.13.2.tgz
  ✔ helm-charts/traefik-39.0.0.tgz
  ✔ images/rancher-images.tar
  ✔ Bundle verified

══ [STEP] Installing K3s Server (Rancher local cluster)
  ✔ K3s server installation complete

══ [STEP] Loading Rancher Container Images
  ✔ Loaded images

══ [STEP] Installing cert-manager
  ✔ cert-manager installed

══ [STEP] Installing Traefik Ingress Controller
  ✔ traefik installed

══ [STEP] Generating Self-Signed Certificates for Rancher
  ✔ Root CA generated
  ✔ Server certificate generated
  ✔ CA certificate installed in system trust store

══ [STEP] Creating Kubernetes TLS Secret
  ✔ TLS secret created in cattle-system namespace
  ✔ TLS CA secret created in cattle-system namespace

══ [STEP] Installing Rancher Management Server
  ✔ Rancher installation complete

══ [STEP] Waiting for Rancher to be Ready
  ✔ Rancher is ready

  ┌──────────────────────────┐
  │  Rancher Server Ready!   │
  └──────────────────────────┘

  ✔ Rancher URL: https://rancher.192.168.64.23.sslip.io
  ✔ Bootstrap Password: changeme
  ✔ IP Address: 192.168.64.23
```

**Installation time:** 10-20 minutes (image loading takes the longest)

---

## Phase 3 — Access Rancher UI

### Verify Services Before Accessing

```bash
# On Rancher VM — check Traefik has External IP assigned
kubectl -n kube-system get svc traefik
# EXTERNAL-IP should show the VM IP (e.g., 192.168.64.23), not <pending>

# Check ingress has the ADDRESS
kubectl -n cattle-system get ingress
# ADDRESS should show 192.168.64.23

# Check all pods are Running
kubectl get pods -A
```

### From Rancher VM (curl test)

```bash
# Test DNS resolution
curl -k https://rancher.192.168.64.23.sslip.io
# Should return JSON: {"type":"collection","links":...}
```

> **Note:** The script automatically adds the `/etc/hosts` entry for airgap DNS. If the domain doesn't resolve, add it manually:
> ```bash
> echo "192.168.64.23 rancher.192.168.64.23.sslip.io" | sudo tee -a /etc/hosts
> ```

### From Your Local Machine (Browser)

1. **sslip.io resolves automatically** if your machine has internet access — no `/etc/hosts` needed on your Mac/PC.

2. **Open in browser:**
   ```
   https://rancher.192.168.64.23.sslip.io
   ```

3. **Handle certificate warning by browser:**

   | Browser | How to Bypass |
   |---------|--------------|
   | Safari | Click "Visit Website" |
   | Chrome | Type `thisisunsafe` directly on the error page (no input box) |
   | Firefox | Click "Advanced" → "Accept the Risk and Continue" |

4. **Install CA cert permanently (optional, removes all warnings):**
   ```bash
   # Copy CA cert from Rancher VM
   scp ubuntu@192.168.64.23:/opt/rancher-certs/rancher-root-ca.crt ~/Downloads/

   # On Mac — install and trust:
   sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain ~/Downloads/rancher-root-ca.crt

   # On Linux:
   sudo cp ~/Downloads/rancher-root-ca.crt /usr/local/share/ca-certificates/
   sudo update-ca-certificates
   ```

5. **Login:**
   - Username: `admin`
   - Password: `changeme` (or what you set with `--bootstrap-password`)

6. **Change admin password** when prompted on first login.

---

## Phase 4 — Import HA K3s Cluster

> **Compatibility:** Rancher is fully compatible with **Cilium + WireGuard** CNI. The `cattle-cluster-agent` runs as a regular pod inside the workload cluster and communicates outbound to Rancher over HTTPS. Cilium handles its networking transparently — no CNI changes required.

### Pre-requirements (Must complete before importing)

#### 1. Pre-load Rancher Agent Image on ALL Workload Nodes

The `rancher-agent` image (~480 MB) must be available on **every node** — controllers and workers — because the agent pod can be scheduled on any of them.

```bash
# Run on EACH node: cp-1, cp-2, worker-1, worker-2, worker-3
sudo k3s ctr images import /opt/offline-bundle/images/rancher-images.tar

# Verify the image loaded successfully:
sudo k3s ctr images list | grep rancher-agent
# Expected output:
# docker.io/rancher/rancher-agent:v2.13.2   application/vnd...  481.6 MiB  linux/arm64
```

> **Note:** The import takes ~60-90 seconds per node. Run it in parallel across nodes using multiple SSH sessions.

#### 2. Add Rancher DNS Entry on ALL Workload Nodes (Airgap)

Since the workload cluster has no internet access, sslip.io cannot resolve via public DNS. Add the entry on every node so the `cattle-cluster-agent` can reach Rancher:

```bash
# Run on EACH node: cp-1, cp-2, worker-1, worker-2, worker-3
echo "192.168.64.23 rancher.192.168.64.23.sslip.io" | sudo tee -a /etc/hosts
```

#### 3. Verify Connectivity from Workload Cluster to Rancher

```bash
# From any workload cluster node:
curl -k https://rancher.192.168.64.23.sslip.io
# Expected: {"type":"collection","links":{"self":"https://rancher.192.168.64.23.sslip.io/"}}
```

---

### Step 1: Generate Import Manifest in Rancher UI

1. Open Rancher UI: `https://rancher.192.168.64.23.sslip.io`
2. Click **☰ (hamburger menu)** → **Cluster Management**
3. Click **Import Existing** (top right button)
4. Select **Generic** cluster type
5. Enter a cluster name (e.g., `k3s-ha-cluster`)
6. Click **Create**
7. Rancher displays the import command — copy it

The import command looks like:
```bash
curl --insecure -sfL https://rancher.192.168.64.23.sslip.io/v3/import/<unique-token>.yaml | kubectl apply -f -
```

---

### Step 2: Run Import Command on Workload Cluster

SSH into **cp-1** (or any controller with kubectl access):

```bash
ssh ubuntu@192.168.64.17

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Verify you are on the WORKLOAD cluster (not Rancher VM)
kubectl get nodes
# Expected: shows cp-1, cp-2, worker-1, worker-2, worker-3

# Run the import command copied from Rancher UI
# (--insecure is required because Rancher uses self-signed certificates)
curl --insecure -sfL \
  https://rancher.192.168.64.23.sslip.io/v3/import/<unique-token>.yaml \
  | kubectl apply -f -
```

---

### Step 3: Monitor Agent Deployment

```bash
# Watch cattle-system pods come up
kubectl -n cattle-system get pods -w
```

**Expected pod progression:**
```
NAME                                  READY   STATUS              AGE
cattle-cluster-agent-xxx-xxx          0/1     ContainerCreating   10s
cattle-cluster-agent-xxx-xxx          0/1     ContainerCreating   20s
cattle-cluster-agent-xxx-xxx          1/1     Running             45s
cattle-cluster-agent-xxx-yyy          1/1     Running             60s
rancher-webhook-xxx-xxx               1/1     Running             90s
system-upgrade-controller-xxx-xxx     1/1     Running             100s
```

**Full expected state after 3-5 minutes:**
```bash
kubectl -n cattle-system get pods
# NAME                                        READY   STATUS      RESTARTS   AGE
# cattle-cluster-agent-8c94c76b5-4shw4        1/1     Running     0          3m20s
# cattle-cluster-agent-8c94c76b5-v9z7x        1/1     Running     0          3m35s
# helm-operation-xxx                          0/2     Completed   0          2m41s
# rancher-webhook-xxx-xxx                     1/1     Running     0          2m17s
# system-upgrade-controller-xxx-xxx           1/1     Running     0          105s
```

---

### Step 4: Verify in Rancher UI

1. Go back to **Cluster Management** in Rancher UI
2. The imported cluster should show status: **Active**
3. Click on the cluster to view:
   - All **5 nodes** (2 controllers + 3 workers) visible
   - Node health, CPU, memory metrics
   - All running workloads and namespaces

---

### Troubleshooting Import Issues

**Agent pod stuck in `ContainerCreating`:**
```bash
kubectl -n cattle-system describe pod cattle-cluster-agent-xxx
# Look for: "Failed to pull image" → rancher-agent image not loaded on that node
# Fix: sudo k3s ctr images import /opt/offline-bundle/images/rancher-images.tar
```

**Agent pod in `CrashLoopBackOff` or connection errors:**
```bash
kubectl -n cattle-system logs -l app=cattle-cluster-agent
# Look for: "connection refused" or "no such host" → /etc/hosts entry missing
# Fix: echo "192.168.64.23 rancher.192.168.64.23.sslip.io" | sudo tee -a /etc/hosts
```

**Cluster shows as `Pending` in Rancher UI for more than 5 minutes:**
```bash
# Re-apply the import manifest
curl --insecure -sfL https://rancher.192.168.64.23.sslip.io/v3/import/<token>.yaml | kubectl apply -f -
```

---

## Rollback

The `rollback-rancher.sh` script provides **granular, automated cleanup** of Rancher and its components.

### Flag Reference

| Flag | Removes | Use Case |
|------|---------|----------|
| `--rancher` | Rancher Helm release, cattle-system namespace, CRDs | Re-install Rancher only |
| `--traefik` | Traefik Helm release and CRDs | Re-install Traefik only |
| `--cert-manager` | cert-manager Helm release, namespace, CRDs | Re-install cert-manager |
| `--certs` | `/opt/rancher-certs/` + system CA trust | Regenerate certificates |
| `--k3s` | K3s server, binaries, all cluster data, KUBECONFIG | Full cluster reset |
| `--all` | Everything above + wipe logs | Complete clean slate |
| `--force` | Skip confirmation prompt | Automation / scripted use |

### Scenario 1: Re-install Rancher only (keep K3s running)

```bash
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --rancher --certs --force

sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23 \
  --bootstrap-password changeme
```

### Scenario 2: Full clean slate

```bash
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --all --force

sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23 \
  --bootstrap-password changeme
```

### Scenario 3: Re-install Traefik + Rancher (keep cert-manager + K3s)

```bash
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --traefik --rancher --certs --force

sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23
```

### Scenario 4: Change Rancher IP or Hostname

```bash
# Remove certs and Rancher (certs are tied to the old IP/hostname)
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --rancher --certs --force

# Re-run with new IP/hostname
sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --rancher-ip 192.168.64.50 \
  --rancher-hostname rancher-new \
  --bootstrap-password changeme
```

### Verify rollback is complete

```bash
systemctl status k3s         || echo "✔ K3s removed"
helm list -A 2>/dev/null     | grep -v "NAME" || echo "✔ No Helm releases"
ls /opt/rancher-certs/       2>/dev/null || echo "✔ Certs removed"
ls /var/log/rancher-install/ 2>/dev/null || echo "✔ Logs wiped"
```

---

## Troubleshooting

### Issue: Bundle verification fails (Missing file)

**Symptom:** `✘ ERROR: Missing: helm-charts/cert-manager-v1.19.4.tgz`

**Solution:** Verify bundle structure matches expected paths:
```bash
ls /opt/offline-bundle/binaries/    # k3s, install.sh, kubectl, helm, crictl
ls /opt/offline-bundle/helm-charts/ # cert-manager-v1.19.4.tgz, rancher-2.13.2.tgz, traefik-39.0.0.tgz
ls /opt/offline-bundle/images/      # k3s-airgap-images-arm64.tar.gz, rancher-images.tar
```

### Issue: Traefik EXTERNAL-IP is `<pending>`

**Symptom:** `kubectl get svc traefik` shows `EXTERNAL-IP: <pending>`

**Cause:** servicelb was disabled in K3s installation.

**Solution:** Verify the K3s install does NOT include `--disable servicelb`. The current script correctly enables servicelb. For an existing install, re-install K3s via rollback + re-install.

### Issue: `tls-ca` secret not found — Rancher pods stuck in ContainerCreating

**Symptom:**
```
MountVolume.SetUp failed for volume "tls-ca-volume" : secret "tls-ca" not found
```

**Cause:** The `tls-ca` secret was not created. This is now automated in the script, but for manual recovery:
```bash
kubectl -n cattle-system create secret generic tls-ca \
  --from-file=cacerts.pem=/opt/rancher-certs/rancher-root-ca.crt

kubectl -n cattle-system rollout restart deployment/rancher
```

### Issue: Can't resolve sslip.io domain (airgap)

**Symptom:** `curl: (6) Could not resolve host: rancher.192.168.64.23.sslip.io`

**Cause:** VM has no internet access to resolve sslip.io public DNS. The install script now adds the `/etc/hosts` entry automatically. For manual fix:
```bash
echo "192.168.64.23 rancher.192.168.64.23.sslip.io" | sudo tee -a /etc/hosts
```

> Also add this on all **workload cluster nodes** so the cattle-cluster-agent can reach Rancher.

### Issue: `curl -k https://192.168.64.23` returns 404

**Cause:** Traefik responds but needs the correct `Host` header to route to Rancher. This is normal when accessing by IP directly. Use the full hostname:
```bash
curl -k https://rancher.192.168.64.23.sslip.io
# Returns: {"type":"collection","links":...}  ← Success
```

### Issue: Chrome blocks Rancher UI (ERR_CERT_INVALID)

**Solution 1 (Quick):** Type `thisisunsafe` directly on the Chrome error page (no input box, just type it).

**Solution 2 (Permanent):** Install the private CA cert on your machine:
```bash
# Copy CA cert from Rancher VM to your Mac
scp ubuntu@192.168.64.23:/opt/rancher-certs/rancher-root-ca.crt ~/Downloads/

# Install and trust on Mac:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/rancher-root-ca.crt
```

### Issue: Rancher pods in CrashLoopBackOff

**Solutions:**
```bash
# Check pod logs
kubectl logs -n cattle-system deployment/rancher

# Verify images are loaded
k3s ctr images list | grep rancher | head -10

# Restart deployment
kubectl rollout restart deployment/rancher -n cattle-system
```

### Issue: Rancher agent image missing on workload nodes

**Symptom:** Import shows cluster as Pending and agent pod stays in `ContainerCreating` or `ImagePullBackOff`.

**Solution:** Load rancher-images.tar on ALL nodes of the workload cluster:
```bash
# Run on every workload node:
sudo k3s ctr images import /opt/offline-bundle/images/rancher-images.tar

# Verify:
sudo k3s ctr images list | grep rancher-agent
```

### Issue: Can't import downstream K3s cluster

**Solutions:**

1. **Verify workload nodes can reach Rancher:**
   ```bash
   # From HA K3s cp-1:
   curl -k https://rancher.192.168.64.23.sslip.io
   ```

2. **Check /etc/hosts on workload nodes:**
   ```bash
   grep rancher /etc/hosts   # Should show entry
   ```

3. **Check agent logs:**
   ```bash
   kubectl logs -n cattle-system -l app=cattle-cluster-agent
   ```

---

## Cilium + WireGuard Compatibility

Rancher is **fully compatible** with your HA K3s cluster using Cilium + WireGuard:

- Rancher runs on a **separate standalone VM** — it doesn't touch the workload cluster's CNI
- The `cattle-cluster-agent` deployed during import runs as a regular pod inside the workload cluster — Cilium routes its traffic transparently
- WireGuard encryption applies to pod-to-pod traffic within the workload cluster — the agent's egress to Rancher goes through standard network routing
- No special Cilium or WireGuard configuration is required for Rancher integration

---

## Maintenance

### Backup Rancher

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Export resource state
kubectl get all -A > rancher-backup.yaml

# Or use Rancher backup UI:
# ☰ → System → Backups
```

### Update Rancher (Future Version)

```bash
# Re-run install script (idempotent — skips completed steps)
sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23
```

### Rollback Rancher

See the full [Rollback](#rollback) section above. Quick reference:

```bash
# Partial rollback — remove Rancher only
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --rancher --certs --force

# Full clean slate
sudo bash ~/k3s_setup/scripts/rollback-rancher.sh --all --force
```

---

## Important Notes

1. **tls-ca secret:** Rancher requires both `rancher-tls` (server cert) and `tls-ca` (CA cert) secrets in `cattle-system`. Both are created automatically by the install script.
2. **servicelb enabled:** K3s runs with servicelb enabled so Traefik's LoadBalancer service gets the node IP as EXTERNAL-IP, enabling standard port 443 access.
3. **Airgap DNS:** In airgap environments, sslip.io cannot be resolved via public DNS. The install script automatically adds a `/etc/hosts` entry on the Rancher VM. Add the same entry on all workload nodes.
4. **Chrome:** Use `thisisunsafe` typed on the error page, or install the private CA cert for a permanent fix.
5. **Default Password:** Change the bootstrap password immediately after first login.
6. **Idempotent:** The script is safe to re-run (checks step markers before each phase).
7. **Logs:** Installation logs are stored in `/var/log/rancher-install/rancher-install.log`

---

## FAQ

**Q: Can I use Rancher to manage multiple K3s clusters?**
A: Yes. After initial setup, import any number of downstream K3s clusters via Cluster Management → Import Existing.

**Q: Is Rancher compatible with Cilium + WireGuard?**
A: Yes. Rancher manages clusters via an agent (cattle-cluster-agent) that runs as a pod inside the cluster. It doesn't interfere with the CNI layer.

**Q: What if I change the Rancher VM IP?**
A: Certificates are tied to the IP. Run rollback with `--rancher --certs`, then re-install with the new IP.

**Q: Do I need to run the import command on every workload node?**
A: No. Run `kubectl apply` once from any node with kubectl access. The agent discovers all nodes via the Kubernetes API.

**Q: Can I uninstall and reinstall Rancher?**
A: Yes. Use `rollback-rancher.sh --all --force`, then re-run the install script.

**Q: Why does direct IP access return 404?**
A: Traefik routes requests by hostname. Always use the full domain `rancher.<IP>.sslip.io` in your browser.

---

## Quick Reference

```bash
# On Rancher VM:

# Check K3s status
systemctl status k3s

# Check all system pods
kubectl get pods -A

# Check Traefik LoadBalancer (EXTERNAL-IP should show VM IP)
kubectl -n kube-system get svc traefik

# Check Rancher ingress
kubectl -n cattle-system get ingress

# View Rancher logs
kubectl -n cattle-system logs -f deployment/rancher

# Set kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Test Rancher UI is accessible
curl -k https://rancher.192.168.64.23.sslip.io

# Reinstall Rancher
sudo bash ~/k3s_setup/scripts/install-rancher.sh \
  --bundle-path /opt/offline-bundle \
  --rancher-ip 192.168.64.23 \
  --bootstrap-password changeme
```

---

**Rancher is now ready to manage your HA K3s cluster and any other downstream clusters!**
