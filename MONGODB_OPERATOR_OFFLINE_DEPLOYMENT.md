# Percona MongoDB Operator — Offline Deployment Guide

Deploy **MongoDB replica sets** on your offline K3s cluster using the Percona MongoDB Operator.
Choose your preferred installation method: **Rancher UI** or **Script/CLI**.

---

## ARM64 / aarch64 Support

✅ **All components in this guide fully support ARM64 (linux/arm64)**, including operator, MongoDB, and backup tool.

> **Key requirement:** ARM64 support requires newer image versions. The versions in this guide are selected specifically for ARM64 compatibility.

| Component | Version | ARM64 Status |
|-----------|---------|---|
| **Percona MongoDB Operator** | **1.22.0** | ✅ Supported (since v1.16.0, May 2024) |
| **MongoDB 7.0** | **7.0.30-16** | ✅ Supported |
| **MongoDB 6.0** | **6.0.27-21** | ✅ Supported |
| **Backup MongoDB** | **2.13.0** | ✅ Supported |

> ⚠️ **Do NOT use older version tags** — versions like `7.0.8-5`, `6.0.15-12`, `2.4.1` are **amd64-only**. Percona added ARM64 images only in newer patch releases.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Phase 0 — Prepare Offline Bundle (Online Machine)](#phase-0--prepare-offline-bundle-online-machine)
4. [Phase 1 — Transfer Bundle to Offline Environment](#phase-1--transfer-bundle-to-offline-environment)
5. [Phase 2 — Load Container Images (Required for Both Methods)](#phase-2--load-container-images-required-for-both-methods)
6. [Phase 3 — Install MongoDB Operator](#phase-3--install-mongodb-operator)
   - [Method A — Via Script / CLI](#method-a--via-script--cli)
   - [Method B — Via Rancher UI](#method-b--via-rancher-ui)
7. [Phase 4 — Deploy MongoDB Cluster](#phase-4--deploy-mongodb-cluster)
   - [Method A — Via kubectl / CLI](#method-a--via-kubectl--cli-1)
   - [Method B — Via Rancher UI](#method-b--via-rancher-ui-1)
8. [Phase 5 — Access MongoDB](#phase-5--access-mongodb)
9. [Storage Setup](#storage-setup)
10. [Verification Checklist](#verification-checklist)
11. [Troubleshooting](#troubleshooting)
12. [Maintenance](#maintenance)
13. [Quick Reference](#quick-reference)

---

## Architecture

```
┌─────────────────────────────────────────┐
│   Rancher Management Server             │
│   (192.168.64.23)                       │
│                                         │
│   Method B: Add local Helm repo → UI    │
│   Method B: Deploy MongoDB CR via UI   │
└─────────────────────────────────────────┘
              │
              │ HTTPS
              ▼
┌─────────────────────────────────────────┐
│   HA K3s Workload Cluster               │
│   (Cilium + WireGuard)                  │
│                                         │
│  📦 Percona MongoDB Operator            │
│  └─ Manages MongoDB Clusters            │
│     └─ PerconaServerMongoDB CR          │
│        └─ 3-node Replica Set            │
│           ├─ my-mongodb-0               │
│           ├─ my-mongodb-1               │
│           └─ my-mongodb-2               │
│                                         │
│  Method A: Install Operator via Script  │
│  Method A: Deploy MongoDB via kubectl   │
└─────────────────────────────────────────┘
```

---

## Prerequisites

### 1. Offline K3s Cluster

✅ Running K3s cluster with:
- Cilium + WireGuard CNI
- All nodes in `Ready` state
- kubectl and helm installed on control plane
- Access via Rancher UI (for Method B)

### 2. Rancher Management Server

✅ Rancher deployed and accessible at: `https://rancher.<IP>.sslip.io`

### 3. Storage Class

MongoDB requires persistent storage. Check available storage classes:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get storageclass
```

**Expected output (K3s default):**
```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

> If no storage class exists, see [Storage Setup](#storage-setup).

---

## Phase 0 — Prepare Offline Bundle (Online Machine)

> Run on an **internet-connected machine** that already has **Docker**, Helm, curl, and python3.
> No additional packages (e.g. skopeo) are required.
>
> ⚠️ **Why not `docker pull --platform`?**
> `docker pull --platform linux/arm64` is unreliable — if an image tag is already cached (even from a previous pull with a different arch), Docker reuses the cache and silently returns the wrong architecture.
>
> **The fix** — two steps, zero extra packages:
> 1. Query the Docker Registry V2 API (`curl` + `python3`) to get the manifest list for the tag and extract the exact digest for `linux/<arch>`.
> 2. Pull by that exact digest: `docker pull repo@sha256:<arch-specific-digest>`
>    Docker **cannot** reuse a cached amd64 layer set for a different digest — it must download the correct arch layers from the registry.

### Requirements (prep machine only)

| Tool | Purpose |
|------|---------|
| `docker` | Pull images and create tarball |
| `helm` | Download operator Helm chart |
| `curl` | Query Docker Registry V2 API |
| `python3` | Parse JSON manifest responses |

All four tools are typically pre-installed on Ubuntu/Debian/macOS.

### Run Bundle Preparation

```bash
cd /path/to/k3s_cluster
chmod +x scripts/prepare-mongodb-operator-bundle.sh

# Architecture is auto-detected from 'uname -m'
./scripts/prepare-mongodb-operator-bundle.sh

# Or specify explicitly if targeting a different arch than your prep machine
./scripts/prepare-mongodb-operator-bundle.sh --arch arm64   # for arm64 clusters
./scripts/prepare-mongodb-operator-bundle.sh --arch amd64   # for x86_64 clusters
```

**Architecture auto-detection:**

| `uname -m` output | Detected arch | Example machines |
|-------------------|---------------|-----------------|
| `aarch64` | `arm64` | Apple Silicon Mac, Raspberry Pi, AWS Graviton |
| `x86_64` | `amd64` | Intel/AMD servers, most cloud VMs |

**Expected output:**
```
  ┌───────────────────────────────────────────────────────┐
  │ Percona MongoDB Operator — Offline Bundle Preparation │
  └───────────────────────────────────────────────────────┘
[INFO]  Output directory: ./offline-bundle/mongodb-operator
[INFO]  MongoDB Operator: 1.22.0
[INFO]  Percona MongoDB:  7.0.30-16
[INFO]  Target Arch:     linux/arm64  (host: aarch64)
[INFO]  ARM64 Support:   ✅ All images support linux/arm64

══ [STEP] Validating Required Tools
  ✔ docker: Docker version 29.x
  ✔ helm: v4.x
  ✔ curl: curl 8.x
  ✔ python3: Python 3.x
  ✔ Docker daemon: running

══ [STEP] Downloading Percona MongoDB Operator Helm Chart
  ✔ Downloaded: psmdb-operator-1.22.0.tgz

══ [STEP] Pulling Docker Images
  ✔ Found linux/arm64 digest in manifest list
  ✔ Pulled & tagged: percona/percona-server-mongodb-operator:1.22.0  (linux/arm64)
  ✔ Found linux/arm64 digest in manifest list
  ✔ Pulled & tagged: percona/percona-server-mongodb:6.0.27-21  (linux/arm64)
  ✔ Found linux/arm64 digest in manifest list
  ✔ Pulled & tagged: percona/percona-server-mongodb:7.0.30-16  (linux/arm64)
  ✔ Found linux/arm64 digest in manifest list
  ✔ Pulled & tagged: percona/percona-backup-mongodb:2.13.0  (linux/arm64)

══ [STEP] Creating Container Image Tarball
  ✔ Image tarball created: ~1.1G (linux/arm64, gzip-compressed)

  ┌────────────────────────────────────┐
  │  MongoDB Operator Bundle Ready!    │
  └────────────────────────────────────┘
  ✔ Location:     ./offline-bundle/mongodb-operator
  ✔ Architecture: linux/arm64
  ✔ Bundle size:  ~1.1 GiB
```

**Images included in bundle:**

| Image | Version | Purpose | Architecture Support |
|-------|---------|---------|-------|
| `percona/percona-server-mongodb-operator` | **1.22.0** | Operator controller | ✅ ARM64 + amd64 |
| `percona/percona-server-mongodb` | **6.0.27-21** | MongoDB 6.0 | ✅ ARM64 + amd64 |
| `percona/percona-server-mongodb` | **7.0.30-16** | MongoDB 7.0 | ✅ ARM64 + amd64 |
| `percona/percona-backup-mongodb` | **2.13.0** | Backup tool | ✅ ARM64 + amd64 |

> ⚠️ **Do NOT use older version tags** — e.g. `7.0.8-5`, `6.0.15-12`, `2.4.1` are **amd64-only**.
> Percona added ARM64 support only in newer patch releases (operator v1.16.0+, MongoDB 6.0.27+/7.0.28+, backup 2.9.1+).

---

## Phase 1 — Transfer Bundle to Offline Environment

### Option A: SCP (Network Transfer)

```bash
# From your online machine to K3s control plane
scp -r ./offline-bundle/mongodb-operator ubuntu@192.168.64.17:/tmp/

# SSH into control plane and move to standard location
ssh ubuntu@192.168.64.17
sudo mkdir -p /opt/mongodb-operator-bundle
sudo mv /tmp/mongodb-operator/* /opt/mongodb-operator-bundle/
```

### Option B: USB Drive (Strict Airgap)

```bash
# Copy to USB on your machine
cp -r ./offline-bundle/mongodb-operator /Volumes/USB_DRIVE/

# On K3s control plane — copy from USB
sudo cp -r /mnt/usb/mongodb-operator/* /opt/mongodb-operator-bundle/
```

**Verify structure on control plane:**
```bash
ls -lh /opt/mongodb-operator-bundle/

# Expected:
# drwxr-xr-x  helm-charts/
# drwxr-xr-x  images/
# -rw-r--r--  MANIFEST.txt
# -rw-r--r--  CHECKSUMS.txt
```

---

## Phase 2 — Load Container Images (Required for Both Methods)

> ⚠️ This step is **mandatory** regardless of whether you use the script or Rancher UI.
> Images must be loaded into K3s containerd on **every cluster node**.

### Load on Control Plane

```bash
ssh ubuntu@192.168.64.17

sudo k3s ctr images import /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz
```

### Load on Each Worker Node

```bash
# Transfer image tarball to each worker
scp /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz ubuntu@192.168.64.19:/tmp/
scp /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz ubuntu@192.168.64.20:/tmp/
scp /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz ubuntu@192.168.64.21:/tmp/

# On each worker node
sudo k3s ctr images import /tmp/mongodb-operator-images.tar.gz
```

**Verify images loaded (run on each node):**
```bash
sudo k3s ctr --namespace k8s.io images list | grep percona

# Expected output:
# docker.io/percona/percona-server-mongodb-operator:1.22.0   ...  linux/arm64
# docker.io/percona/percona-server-mongodb:6.0.27-21         ...  linux/arm64
# docker.io/percona/percona-server-mongodb:7.0.30-16           ...  linux/arm64
# docker.io/percona/percona-backup-mongodb:2.13.0          ...  linux/arm64
```

---

## Phase 3 — Install MongoDB Operator

Choose **one** of the two methods below.

---

### Method A — Via Script / CLI

Run the automated installer on your **K3s control plane**:

```bash
# Copy script to control plane (if not already there)
scp scripts/install-mongodb-operator.sh ubuntu@192.168.64.17:~/

# SSH to control plane
ssh ubuntu@192.168.64.17

# Run installer
sudo bash ~/install-mongodb-operator.sh \
  --bundle-path /opt/mongodb-operator-bundle \
  --namespace mongodb
```

**Script flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--bundle-path` | `/opt/mongodb-operator-bundle` | Path to offline bundle |
| `--namespace` | `mongodb` | K8s namespace for operator |
| `--kubeconfig` | `/etc/rancher/k3s/k3s.yaml` | Path to kubeconfig |

**Expected output:**
```
  ┌──────────────────────────────────────────┐
  │ Percona MongoDB Operator — Installation  │
  └──────────────────────────────────────────┘

══ [STEP] Verifying Offline Bundle
  ✔ helm-charts/psmdb-operator-1.22.0.tgz
  ✔ images/mongodb-operator-images.tar.gz
  ✔ MANIFEST.txt

══ [STEP] Checking System Prerequisites
  ✔ Kubernetes cluster accessible
  ✔ Helm found
  ✔ K3s containerd available

══ [STEP] Loading Container Images into K3s
  ✔ Images loaded successfully
  ✔ Verified: 4 Percona images available

══ [STEP] Creating MongoDB Namespace
  ✔ Namespace 'mongodb' created

══ [STEP] Installing Percona MongoDB Operator
  ✔ Operator installed successfully

══ [STEP] Verifying Operator Deployment
  ✔ Operator is ready (45s)

  ┌──────────────────────────────────────────┐
  │   MongoDB Operator Deployed!             │
  └──────────────────────────────────────────┘
```

**Verify:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get pods -n mongodb
# NAME                       READY   STATUS    RESTARTS   AGE
# psmdb-operator-xxx-yyy     1/1     Running   0          2m

kubectl get deployment -n mongodb
# NAME             READY   UP-TO-DATE   AVAILABLE   AGE
# psmdb-operator   1/1     1            1           2m
```

---

### Method B — Via Rancher UI

> **Rancher 2.13.x does not support direct chart file upload** in the Apps → Charts page.
> The correct approach is to serve the Helm chart over HTTP from a cluster node, then register
> it as a repository in Rancher UI. This takes ~2 minutes to set up.

#### Step 1: Serve Helm Charts via HTTP on Control Plane

SSH into your control plane and start a lightweight HTTP file server:

```bash
ssh ubuntu@192.168.64.17

# Navigate to the helm-charts bundle directory
cd /opt/mongodb-operator-bundle/helm-charts

# Generate Helm repository index
helm repo index .

# Start Python HTTP server in background (port 8888)
nohup python3 -m http.server 8888 &

# Verify it's running
curl -s http://localhost:8888/index.yaml | head -5
# Expected: apiVersion: v1 ...
```

> **Note:** This HTTP server only needs to run during chart installation. You can stop it with `kill %1` afterwards.

#### Step 2: Create Namespace in Rancher UI

1. Open Rancher UI → `https://rancher.192.168.64.23.sslip.io`
2. Select your cluster from the top dropdown
3. Go to **☰ → Cluster → Projects/Namespaces**
4. Click **Create Namespace**
   - **Name:** `mongodb`
5. Click **Create**

#### Step 3: Add Local Helm Repository

1. Go to **☰ → Apps → Repositories**
2. Click **Create** (top right)
3. Fill in:

   | Field | Value |
   |-------|-------|
   | **Name** | `mongodb-operator-local` |
   | **Index URL** | `http://192.168.64.17:8888/index.yaml` |
   | **Type** | `http` |

4. Click **Create**
5. Wait for the repository status to show **Active** ✅

#### Step 4: Install Operator from Charts

1. Go to **☰ → Apps → Charts**
2. In the top filter bar, select repository: **`mongodb-operator-local`**
3. Click on **psmdb-operator** chart
4. Click **Install** (top right)

#### Step 5: Configure Helm Install

In the installation wizard:

| Field | Value |
|-------|-------|
| **Name** | `psmdb-operator` |
| **Namespace** | `mongodb` |

- Click **Next**
- On the **Values** step, click **Edit YAML** and verify or add:
  ```yaml
  rbac:
    create: true
    serviceAccountName: psmdb-operator
  ```
- Click **Install**

Watch the install log at the bottom — it will show `SUCCESS` when complete.

#### Step 6: Verify via Rancher UI

1. Go to **☰ → Workload → Pods**
2. Filter namespace to **`mongodb`**
3. Verify pod `psmdb-operator-xxx` shows **Running** ✅

#### Step 7: Stop HTTP Server (Cleanup)

```bash
ssh ubuntu@192.168.64.17

# Find and stop the python HTTP server
pkill -f "python3 -m http.server 8888"
```

---

## Phase 4 — Deploy MongoDB Cluster

> The MongoDB Operator is now running. Choose how to create your MongoDB cluster.
>
> ⚠️ **v1.22.0 API change:** The spec uses `replsets[].volumeSpec.persistentVolumeClaim` for storage
> (NOT the old top-level `storage` block). Using the old format causes `volumeSpec should be specified` error.

---

### Method A — Via kubectl / CLI

#### Step 1: Create Cluster Secrets

The v1.22.0 operator uses a **single secret** with named keys (not separate per-user secrets):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n mongodb create secret generic my-mongodb-cluster-secrets \
  --from-literal=MONGODB_CLUSTER_ADMIN_PASSWORD='ClusterAdminPassword123!' \
  --from-literal=MONGODB_CLUSTER_MONITOR_PASSWORD='MonitorPassword123!' \
  --from-literal=MONGODB_USER_ADMIN_PASSWORD='UserAdminPassword123!' \
  --from-literal=MONGODB_BACKUP_PASSWORD='BackupPassword123!'
```

#### Step 2: Apply MongoDB Cluster YAML

```bash
kubectl apply -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: my-mongodb-cluster
  namespace: mongodb
spec:
  crVersion: 1.22.0
  image: percona/percona-server-mongodb:7.0.30-16
  imagePullPolicy: IfNotPresent
  replsets:
  - name: rs0
    size: 3
    resources:
      limits:
        cpu: "1"
        memory: 2Gi
      requests:
        cpu: 500m
        memory: 1Gi
    volumeSpec:
      persistentVolumeClaim:
        accessModes:
        - ReadWriteOnce
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
  secrets:
    users: my-mongodb-cluster-secrets
  upgradeOptions:
    apply: Never
    schedule: "0 2 * * *"
EOF
```

```bash
# Watch pods come up
kubectl get pods -n mongodb -w

# Watch cluster status
kubectl get psmdb -n mongodb -w
```

**Expected cluster status progression:**
```
NAME                 STATUS        READY
my-mongodb-cluster   initializing  false
my-mongodb-cluster   initializing  false
my-mongodb-cluster   ready         true     ← Done (~3-5 min)
```

**Expected pods:**
```
NAME                             READY   STATUS    AGE
my-mongodb-cluster-rs0-0         1/1     Running   2m
my-mongodb-cluster-rs0-1         1/1     Running   100s
my-mongodb-cluster-rs0-2         1/1     Running   60s
psmdb-operator-xxx               1/1     Running   20m
```

---

### Method B — Via Rancher UI (kubectl shell)

> **Note:** The **`☰ → Cluster → Custom Resources`** path may not be visible in Rancher 2.13.x.
> Use the **built-in kubectl shell** instead — it's available in every Rancher version.

#### Step 1: Open kubectl Shell

In your cluster view, click the **`>_`** terminal icon (top right of the Rancher UI).

#### Step 2: Create Cluster Secrets

Paste in the shell:

```bash
kubectl -n mongodb create secret generic my-mongodb-cluster-secrets \
  --from-literal=MONGODB_CLUSTER_ADMIN_PASSWORD='ClusterAdminPassword123!' \
  --from-literal=MONGODB_CLUSTER_MONITOR_PASSWORD='MonitorPassword123!' \
  --from-literal=MONGODB_USER_ADMIN_PASSWORD='UserAdminPassword123!' \
  --from-literal=MONGODB_BACKUP_PASSWORD='BackupPassword123!'
```

#### Step 3: Apply MongoDB Cluster YAML

```bash
kubectl apply -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: my-mongodb-cluster
  namespace: mongodb
spec:
  crVersion: 1.22.0
  image: percona/percona-server-mongodb:7.0.30-16
  imagePullPolicy: IfNotPresent
  replsets:
  - name: rs0
    size: 3
    resources:
      limits:
        cpu: "1"
        memory: 2Gi
      requests:
        cpu: 500m
        memory: 1Gi
    volumeSpec:
      persistentVolumeClaim:
        accessModes:
        - ReadWriteOnce
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
  secrets:
    users: my-mongodb-cluster-secrets
  upgradeOptions:
    apply: Never
    schedule: "0 2 * * *"
EOF
```

#### Step 4: Monitor in Rancher UI

Go to **☰ → Workload → Pods** → filter namespace to **`mongodb`**

Wait for all pods to show **Running** ✅:
```
my-mongodb-cluster-rs0-0   1/1   Running
my-mongodb-cluster-rs0-1   1/1   Running
my-mongodb-cluster-rs0-2   1/1   Running
```
**Expected time:** 3–5 minutes

---

## Phase 5 — Access MongoDB

### Get Service Endpoints

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n mongodb get svc
# NAME                          TYPE        CLUSTER-IP      PORT(S)
# my-mongodb-cluster-rs0        ClusterIP   10.43.xxx.xxx   27017/TCP
# my-mongodb-cluster-rs0-0      ClusterIP   None            27017/TCP
# my-mongodb-cluster-rs0-1      ClusterIP   None            27017/TCP
# my-mongodb-cluster-rs0-2      ClusterIP   None            27017/TCP
```

> The primary service for the replica set is `my-mongodb-cluster-rs0` (not `my-mongodb-cluster`).

**Internal connection string (from within cluster):**
```
mongodb://userAdmin:UserAdminPassword123!@my-mongodb-cluster-rs0.mongodb.svc.cluster.local:27017/admin
```

### Get Admin Password

```bash
# Retrieve the password you set in the secret
kubectl -n mongodb get secret my-mongodb-cluster-secrets \
  -o jsonpath='{.data.MONGODB_USER_ADMIN_PASSWORD}' | base64 -d
```

### Test Connection (Port Forward)

```bash
# Forward port to your local machine
kubectl -n mongodb port-forward svc/my-mongodb-cluster-rs0 27017:27017 &

# Connect via mongosh
mongosh "mongodb://userAdmin:UserAdminPassword123!@localhost:27017/admin"

# Verify replica set status inside mongosh
rs.status()
```

### Connect Directly into a Pod

```bash
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin
```

### Expose MongoDB Externally via NodePort (Optional)

**Method A — kubectl:**
```bash
kubectl -n mongodb expose svc my-mongodb-cluster-rs0 \
  --name=mongodb-nodeport \
  --type=NodePort \
  --port=27017 \
  --target-port=27017
```

**Method B — Rancher UI:**
1. Go to **☰ → Workload → Services**
2. Click **Create** → **NodePort**
3. Configure:
   - **Name:** `mongodb-nodeport`
   - **Namespace:** `mongodb`
   - **Port:** `27017`, **Target Port:** `27017`, **Node Port:** `31017`
   - **Selector:** `app.kubernetes.io/instance: my-mongodb-cluster`
4. Click **Create**

**Access from outside cluster:**
```
mongodb://userAdmin:UserAdminPassword123!@192.168.64.17:31017/admin
```

---

## Storage Setup

If `local-path` is not your default storage class, create PersistentVolumes manually:

```yaml
# Apply via kubectl or Rancher UI (YAML editor)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mongodb-local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mongodb-pv-1
spec:
  capacity:
    storage: 10Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: mongodb-local-storage
  local:
    path: /mnt/mongodb-storage
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker-1  # Replace with actual node name
```

Create the storage directory on the target node:
```bash
sudo mkdir -p /mnt/mongodb-storage
```

---

## Verification Checklist

- [ ] All container images loaded on every node (`linux/arm64`)
- [ ] Operator pod `psmdb-operator-xxx` is `Running`
- [ ] MongoDB pods `my-mongodb-cluster-rs0-0/1/2` are all `1/1 Running`
- [ ] PersistentVolumeClaims are `Bound`
- [ ] Secret `my-mongodb-cluster-secrets` exists in `mongodb` namespace
- [ ] MongoDB service `my-mongodb-cluster-rs0` is listening on port 27017
- [ ] `kubectl get psmdb -n mongodb` shows `state: ready`
- [ ] Replica set status is `PRIMARY/SECONDARY`:
  ```bash
  kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
    mongosh --authenticationDatabase admin -u userAdmin -p 'UserAdminPassword123!' \
    --eval "rs.status().members.forEach(m => print(m.name, m.stateStr))"
  ```

---

## Troubleshooting

### Issue: MongoDB pods stuck in `Pending`

**Cause:** No storage available.

```bash
kubectl -n mongodb describe pvc
# Check "Events" section for storage errors

kubectl get storageclass
# Verify storageClassName matches your cluster
```

### Issue: `ImagePullBackOff` on any pod

**Cause:** Container images not loaded on that node.

```bash
# On the affected node, check which images are available:
sudo k3s ctr --namespace k8s.io images list | grep percona

# If missing, reload:
sudo k3s ctr images import /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz
```

### Issue: Operator pod in `CrashLoopBackOff` with `exec format error`

**Cause:** Container images were built for a different CPU architecture (e.g., `amd64` images on an `arm64` cluster).

**Diagnose:**
```bash
# Check architecture of loaded images — must match cluster nodes
sudo k3s ctr --namespace k8s.io images list | grep percona
# Look at the last column — must show linux/arm64, NOT linux/amd64
```

**Fix — Re-prepare bundle with correct architecture on the online machine:**
```bash
# On online/bundle-prep machine
./scripts/prepare-mongodb-operator-bundle.sh --arch arm64

# Transfer new tarball to cluster
scp ./offline-bundle/mongodb-operator/images/mongodb-operator-images.tar.gz \
    ubuntu@192.168.64.17:/tmp/
```

**Fix — Replace wrong-arch images on EVERY cluster node:**
```bash
# Run on cp-1, cp-2, worker-01, worker-02, worker-03

# Remove wrong amd64 images
sudo k3s ctr --namespace k8s.io images rm \
    docker.io/percona/percona-server-mongodb-operator:1.22.0 \
    docker.io/percona/percona-server-mongodb:6.0.27-21 \
    docker.io/percona/percona-server-mongodb:7.0.30-16 \
    docker.io/percona/percona-backup-mongodb:2.13.0

# Import correct arm64 images
sudo k3s ctr images import /tmp/mongodb-operator-images.tar.gz

# Verify — must show linux/arm64
sudo k3s ctr --namespace k8s.io images list | grep percona | awk '{print $1, $NF}'
```

**Fix — Restart the operator:**
```bash
kubectl rollout restart deployment/psmdb-operator -n mongodb
kubectl get pods -n mongodb -w
# Operator pod should now reach Running without CrashLoopBackOff
```

### Issue: Operator pod in `CrashLoopBackOff` (other causes)

```bash
kubectl logs -n mongodb -l app.kubernetes.io/name=psmdb-operator --tail=50

# Reload images if needed, then restart:
kubectl rollout restart deployment/psmdb-operator -n mongodb
```

### Issue: Can't find `PerconaServerMongoDB` in Rancher UI

**Note:** In Rancher 2.13.x, `☰ → Cluster → Custom Resources` may not be directly accessible via the sidebar.

**Use the kubectl shell instead (>_ button in Rancher top right):**
```bash
# Verify CRDs are installed:
kubectl get crd | grep percona

# Expected:
# perconaservermongodbs.psmdb.percona.com
# perconaservermongodbbackups.psmdb.percona.com
# perconaservermongodbrestores.psmdb.percona.com

# If missing, re-install operator:
helm upgrade --install psmdb-operator \
  /opt/mongodb-operator-bundle/helm-charts/psmdb-operator-1.22.0.tgz \
  -n mongodb
```

**Alternative — use Rancher top search bar:**
Click the 🔍 search icon in Rancher and type `PerconaServerMongoDB` to navigate directly to the CRD.

### Issue: `volumeSpec should be specified` error on cluster creation

**Cause:** Using the old API spec format (pre-1.22.0). The `storage` block at the replset level is no longer valid.

**Fix:** Use `volumeSpec.persistentVolumeClaim` inside each replset entry:
```yaml
replsets:
- name: rs0
  size: 3
  volumeSpec:                          # ← required in v1.22.0+
    persistentVolumeClaim:
      accessModes: [ReadWriteOnce]
      storageClassName: local-path
      resources:
        requests:
          storage: 10Gi
```

### Issue: MongoDB cluster stuck in `initializing`

```bash
# Check operator logs
kubectl logs -n mongodb -l app.kubernetes.io/name=psmdb-operator -f

# Check MongoDB pod logs
kubectl logs -n mongodb my-mongodb-cluster-rs0-0 --all-containers

# Describe the PSMDB resource — check status.message
kubectl -n mongodb describe psmdb my-mongodb-cluster
```

### Issue: Can't connect to MongoDB

```bash
# Verify service exists (look for my-mongodb-cluster-rs0)
kubectl -n mongodb get svc

# Verify all 3 pods are 1/1 Ready
kubectl -n mongodb get pods

# Connect directly into pod
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh --authenticationDatabase admin -u userAdmin -p 'UserAdminPassword123!'
```

---

## Maintenance

### Scale Replica Set

```bash
kubectl -n mongodb patch psmdb my-mongodb-cluster \
  --type merge -p '{"spec":{"replsets":[{"name":"rs0","size":5}]}}'
```

### Update MongoDB Version (Zero-Downtime Upgrade)

The Percona operator performs **rolling updates** — each replica member is upgraded one at a time, so your cluster remains available throughout.

#### Step 1: Backup Before Upgrade (CRITICAL)

```bash
# Create a backup snapshot
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "db.adminCommand({fsync: 1})"

# Optional: Create a logical backup with mongodump
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongodump -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --out /data/db/backup-$(date +%Y%m%d)
```

#### Step 2: Prepare Images on All Nodes

Load the new MongoDB image on **every cluster node** before initiating the upgrade:

```bash
# Download the new version image on internet machine
# Example: upgrading from 7.0.30-16 to 8.0.19-7
docker pull percona/percona-server-mongodb:8.0.19-7

# Tag and save as tar
docker save percona/percona-server-mongodb:8.0.19-7 -o percona-server-mongodb-8019-7.tar

# Copy image to each node
scp percona-server-mongodb-8019-7.tar ubuntu@<node-ip>:/tmp/percona-server-mongodb-8019-7.tar

# On EACH node (cp-1, cp-2, worker-01, worker-02, worker-03): import image
ssh ubuntu@<node-ip>

sudo k3s ctr images import /tmp/percona-server-mongodb-8019-7.tar

# Verify it's loaded
sudo k3s ctr --namespace k8s.io images list | grep percona-server-mongodb
```

#### Step 3: Initiate Rolling Update

```bash
# Update the image in the cluster spec
kubectl -n mongodb patch psmdb my-mongodb-cluster \
  --type merge \
  -p '{"spec":{"image":"percona/percona-server-mongodb:8.0.19-7"}}'

# Watch the rolling update progress
kubectl -n mongodb get pods -w

# Monitor the upgrade (watch for pod restarts one at a time):
# Expected behavior:
# - rs0-2 pod restarts first (SECONDARY)
# - rs0-1 pod restarts second (SECONDARY)
# - rs0-0 pod restarts last (PRIMARY) — briefly loses primary status, then re-elected
```

#### Step 4: Monitor Upgrade Progress

```bash
# Check PSMDB cluster status
kubectl -n mongodb get psmdb my-mongodb-cluster -o yaml | grep -A 10 "status:"

# Expected progression:
# - ready: false → true (takes ~3-5 min)
# - size: 0 → 3

# Check individual pod versions
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "db.serverStatus().version"
```

#### Step 5: Verify Upgrade Success

```bash
# Check all pods running new version
kubectl -n mongodb get pods -n mongodb

# Verify replica set is healthy
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "rs.status().members.forEach(m => print(m.name, m.stateStr, 'OK'))"

# Check data integrity with a simple query
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "db.adminCommand('dbStats')"
```

#### Upgrade Compatibility Matrix (ARM64)

| From | To | Breaking Changes | Time |
|------|-----|-----------------|------|
| 6.0.27-21 | 7.0.30-16 | None (forward-compatible) | ~3-5 min |
| 7.0.30-16 | 8.0.19-7 | None (forward-compatible) | ~3-5 min |
| 6.0.27-21 | 8.0.19-7 | Major version jump — test in dev first | ~5-7 min |

> **⚠️ Always upgrade to intermediate versions first if jumping multiple major versions.**

#### Rollback If Upgrade Fails

```bash
# Immediately revert to previous version
kubectl -n mongodb patch psmdb my-mongodb-cluster \
  --type merge \
  -p '{"spec":{"image":"percona/percona-server-mongodb:7.0.30-16"}}'

# Monitor rollback
kubectl -n mongodb get pods -w

# Verify rolled back
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "db.serverStatus().version"

# Restore from backup if needed
kubectl -n mongodb cp my-mongodb-cluster-rs0-0:/data/db/backup-* ./backup-restore/
```

---

### Automated Backups with Percona Backup for MongoDB

The operator can schedule **automatic backups** using the deployed Backup tool:

#### Configure Daily Backups

```bash
kubectl apply -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: daily-backup
  namespace: mongodb
spec:
  psmdbCluster: my-mongodb-cluster
  backupType: logical  # or 'physical' for faster backups
  compressionType: gzip

  # Schedule via CronJob
  schedule: "0 2 * * *"  # 2 AM daily

  # Or run manually with backupType: "on-demand"

  # Storage destination (optional — uses PVC by default)
  # storageType: s3  # for cloud backups
  # s3:
  #   bucket: "my-backups"
  #   credentials: s3-secret
EOF

# Watch backup jobs
kubectl get psmdbbackup -n mongodb -w

# List completed backups
kubectl get psmdbbackup -n mongodb -o wide
```

#### Manual One-Time Backup

```bash
# Create a backup job right now
kubectl apply -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  name: pre-upgrade-backup-$(date +%s)
  namespace: mongodb
spec:
  psmdbCluster: my-mongodb-cluster
  backupType: logical
EOF

# Monitor until completion
kubectl get psmdbbackup -n mongodb -w

# Get backup details
kubectl describe psmdbbackup -n mongodb pre-upgrade-backup-<timestamp>
```

#### Restore from Backup

```bash
# Create a new cluster from a backup
kubectl apply -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  name: restore-from-backup
  namespace: mongodb
spec:
  clusterName: my-mongodb-cluster
  backupName: daily-backup-0  # name of the backup to restore
  backupSource: cluster-backup  # backup storage location
EOF

# Monitor restore progress
kubectl get psmdbrestores -n mongodb -w

# Verify restored data
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "db.adminCommand('dbStats')"
```

---

### Delete MongoDB Cluster

```bash
# Removes cluster but retains PersistentVolumes
kubectl -n mongodb delete psmdb my-mongodb-cluster
```

---

## Quick Reference

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- Operator ---
# Check operator
kubectl get pods -n mongodb -l app.kubernetes.io/name=psmdb-operator

# Operator logs
kubectl logs -n mongodb -l app.kubernetes.io/name=psmdb-operator -f

# --- MongoDB Cluster ---
# List clusters
kubectl get psmdb -n mongodb

# Watch cluster status
kubectl get psmdb -n mongodb -w

# Describe cluster
kubectl -n mongodb describe psmdb my-mongodb-cluster

# --- Pods & Storage ---
# List all pods
kubectl get pods -n mongodb

# Check persistent volumes
kubectl get pvc -n mongodb

# --- Connect ---
# Port forward for local access
kubectl -n mongodb port-forward svc/my-mongodb-cluster-rs0 27017:27017

# Shell into MongoDB pod
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- mongosh

# Check replica set status
kubectl -n mongodb exec -it my-mongodb-cluster-rs0-0 -- \
  mongosh -u userAdmin -p 'UserAdminPassword123!' --authenticationDatabase admin \
  --eval "rs.status().members.forEach(m => print(m.name, m.stateStr))"

# --- Images (per node) ---
# Verify images loaded
sudo k3s ctr --namespace k8s.io images list | grep percona

# Reload images
sudo k3s ctr images import /opt/mongodb-operator-bundle/images/mongodb-operator-images.tar.gz
```

---

## Method Comparison

| Feature | Method A (Script/CLI) | Method B (Rancher UI) |
|---------|----------------------|----------------------|
| Setup speed | ✅ Faster (automated) | ⏱ Slower (manual steps) |
| Technical skill required | Medium (SSH + CLI) | Low (browser only) |
| Repeatable/scriptable | ✅ Yes | ❌ Manual |
| Visual monitoring | ❌ CLI only | ✅ Dashboard + logs |
| Recommended for | CI/CD, automation, ops | First-time setup, demos |

---

## Rollback & Recovery

Use these steps if anything goes wrong at any phase. Each section is **independent** — roll back only the phase that failed.

---

### Rollback: Phase 2 — Remove Wrong-Architecture Images

**When to use:** Images loaded are wrong architecture (`linux/amd64` instead of `linux/arm64`).

```bash
# Run on EACH affected node (cp-1, cp-2, worker-01, worker-02, worker-03)
ssh ubuntu@<node-ip>

# Step 1: Remove wrong-arch images
sudo k3s ctr --namespace k8s.io images rm \
    docker.io/percona/percona-server-mongodb-operator:1.22.0 \
    docker.io/percona/percona-server-mongodb:6.0.27-21 \
    docker.io/percona/percona-server-mongodb:7.0.30-16 \
    docker.io/percona/percona-backup-mongodb:2.13.0

# Step 2: Verify removed
sudo k3s ctr --namespace k8s.io images list | grep percona
# Should return empty

# Step 3: Re-import correct arm64 images (after re-preparing bundle with --arch arm64)
sudo k3s ctr images import /tmp/mongodb-operator-images.tar.gz

# Step 4: Verify correct architecture
sudo k3s ctr --namespace k8s.io images list | grep percona | awk '{print $1, $NF}'
# Must show: linux/arm64
```

---

### Rollback: Phase 3 — Uninstall MongoDB Operator

**When to use:** Operator installed incorrectly, wrong version, CrashLoopBackOff, or want a clean reinstall.

**Method A — CLI:**
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Uninstall Helm release (removes operator deployment + RBAC)
helm uninstall psmdb-operator -n mongodb

# Verify operator pods are gone
kubectl get pods -n mongodb
# Should show: No resources found in mongodb namespace.

# Remove CRDs (only if you want a full clean slate — this also deletes all MongoDB clusters!)
kubectl delete crd \
    perconaservermongodbs.psmdb.percona.com \
    perconaservermongodbbackups.psmdb.percona.com \
    perconaservermongodbrestores.psmdb.percona.com

# Verify CRDs removed
kubectl get crd | grep percona
# Should return empty
```

**Method B — Rancher UI:**
1. Go to **☰ → Apps → Installed Apps**
2. Find **psmdb-operator** → Click **⋮** → **Delete**
3. Confirm deletion

> ⚠️ Deleting the operator CRDs also removes all `PerconaServerMongoDB` resources. **MongoDB data on PVs is retained** unless you also delete the PVCs.

---

### Rollback: Phase 4 — Delete MongoDB Cluster

**When to use:** MongoDB cluster is misconfigured, stuck, or you need to redeploy from scratch.

#### Option A: Delete cluster only (keeps data on PVs)

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Delete the MongoDB cluster resource
kubectl -n mongodb delete psmdb my-mongodb-cluster

# Watch cleanup — operator will remove StatefulSet, pods, services
kubectl get pods -n mongodb -w

# Verify only operator pod remains
kubectl get pods -n mongodb
# NAME                       READY   STATUS    RESTARTS   AGE
# psmdb-operator-xxx-yyy     1/1     Running   0          10m

# PVCs are retained (data safe)
kubectl get pvc -n mongodb
```

#### Option B: Delete cluster AND wipe all data

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Delete the MongoDB cluster
kubectl -n mongodb delete psmdb my-mongodb-cluster

# Wait for pods to terminate
kubectl get pods -n mongodb -w

# Delete all PersistentVolumeClaims (⚠️ DATA LOSS — irreversible)
kubectl -n mongodb delete pvc --all

# Delete secrets
kubectl -n mongodb delete secret mongodb-admin-secret mongodb-app-secret

# Verify namespace is clean (only operator pod remains)
kubectl get all -n mongodb
```

#### Option C: Via Rancher UI

1. Go to **☰ → Cluster → Custom Resources → PerconaServerMongoDB**
2. Click **⋮** next to `my-mongodb-cluster` → **Delete**
3. For PVCs: Go to **☰ → Storage → PersistentVolumeClaims** → filter `mongodb` → delete

---

### Rollback: Phase 3 + 4 — Uninstall Operator AND Delete MongoDB Cluster

**When to use:** Complete removal of MongoDB operator and all clusters.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Step 1: Delete all MongoDB clusters first (graceful shutdown)
kubectl -n mongodb delete psmdb --all

# Step 2: Wait for all MongoDB pods to terminate
kubectl get pods -n mongodb -w
# Wait until only psmdb-operator pod remains

# Step 3: Uninstall the operator Helm release
helm uninstall psmdb-operator -n mongodb

# Step 4: Delete CRDs (removes all Percona MongoDB custom resource definitions)
kubectl delete crd \
    perconaservermongodbs.psmdb.percona.com \
    perconaservermongodbbackups.psmdb.percona.com \
    perconaservermongodbrestores.psmdb.percona.com

# Step 5: (Optional) Delete PVCs if you want to wipe data
kubectl -n mongodb delete pvc --all

# Step 6: (Optional) Delete namespace entirely
kubectl delete namespace mongodb

# Verify everything is gone
kubectl get all -n mongodb 2>&1 || echo "Namespace deleted"
kubectl get crd | grep percona  # Should return empty
```

---

### Rollback: Full Reset — Everything (Bundle + Cluster)

**When to use:** Start completely from scratch — wrong architecture images, wrong versions, or major misconfiguration.

#### Step 1: Clean Up Cluster

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Delete MongoDB clusters
kubectl -n mongodb delete psmdb --all --ignore-not-found

# Uninstall operator
helm uninstall psmdb-operator -n mongodb --ignore-not-found

# Delete CRDs
kubectl delete crd \
    perconaservermongodbs.psmdb.percona.com \
    perconaservermongodbbackups.psmdb.percona.com \
    perconaservermongodbrestores.psmdb.percona.com \
    --ignore-not-found

# Delete PVCs (data wipe)
kubectl -n mongodb delete pvc --all --ignore-not-found

# Delete namespace
kubectl delete namespace mongodb --ignore-not-found
```

#### Step 2: Remove Wrong Images from ALL Nodes

```bash
# Run on EACH node: cp-1, cp-2, worker-01, worker-02, worker-03
for node in 192.168.64.17 192.168.64.18 192.168.64.19 192.168.64.20 192.168.64.21; do
    echo "=== Cleaning node $node ==="
    ssh ubuntu@$node "
        sudo k3s ctr --namespace k8s.io images rm \
            docker.io/percona/percona-server-mongodb-operator:1.22.0 \
            docker.io/percona/percona-server-mongodb:6.0.27-21 \
            docker.io/percona/percona-server-mongodb:7.0.30-16 \
            docker.io/percona/percona-backup-mongodb:2.13.0 \
            2>/dev/null || true
        echo 'Images removed on $node'
    "
done
```

#### Step 3: Remove Old Bundle (Online Machine)

```bash
# On the online/bundle-prep machine
rm -rf ./offline-bundle/mongodb-operator/

# Re-prepare with correct architecture
./scripts/prepare-mongodb-operator-bundle.sh --arch arm64
```

#### Step 4: Re-transfer Bundle

```bash
# Transfer new correct-arch bundle to control plane
scp -r ./offline-bundle/mongodb-operator ubuntu@192.168.64.17:/tmp/
ssh ubuntu@192.168.64.17 "sudo rm -rf /opt/mongodb-operator-bundle && sudo mv /tmp/mongodb-operator /opt/mongodb-operator-bundle"
```

#### Step 5: Re-install from Scratch

```bash
# Follow from Phase 2 in this guide:
# Phase 2: Load images on all nodes
# Phase 3: Install operator (Method A or B)
# Phase 4: Deploy MongoDB cluster
```

---

## Rollback Quick Reference

| Scenario | Command |
|----------|---------|
| Wrong arch images on a node | `sudo k3s ctr --namespace k8s.io images rm docker.io/percona/...` |
| Operator CrashLoopBackOff | `kubectl rollout restart deployment/psmdb-operator -n mongodb` |
| Reinstall operator only | `helm uninstall psmdb-operator -n mongodb` then reinstall |
| Delete MongoDB cluster (keep data) | `kubectl -n mongodb delete psmdb my-mongodb-cluster` |
| Delete MongoDB cluster + data | Delete psmdb + `kubectl -n mongodb delete pvc --all` |
| Remove operator + all clusters | `helm uninstall psmdb-operator -n mongodb` + delete CRDs |
| Full reset (everything) | See "Full Reset" section above |

---

**MongoDB Cluster is ready for use!** 🍃
