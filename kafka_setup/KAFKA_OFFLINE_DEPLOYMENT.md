# Strimzi Kafka — Offline Deployment Guide

Deploy a **3-broker Kafka HA cluster** on your offline K3s cluster using the Strimzi operator and KRaft mode (no ZooKeeper).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AIR-GAPPED K3s CLUSTER                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │            kafka namespace                                   │   │
│  │                                                             │   │
│  │  ┌───────────────────────────────┐                         │   │
│  │  │   strimzi-cluster-operator    │  ← Deployment (1 pod)  │   │
│  │  │   (watches Kafka CRDs)        │                         │   │
│  │  └───────────────┬───────────────┘                         │   │
│  │                  │ provisions                               │   │
│  │                  ▼                                          │   │
│  │  ┌──────────────────────────────────────────────────────┐  │   │
│  │  │  KafkaNodePool: "kafka"  (3 replicas, KRaft)         │  │   │
│  │  │                                                       │  │   │
│  │  │  worker-01 ──► kafka-cluster-kafka-0  [ctrl+broker]  │  │   │
│  │  │  worker-02 ──► kafka-cluster-kafka-1  [ctrl+broker]  │  │   │
│  │  │  worker-03 ──► kafka-cluster-kafka-2  [ctrl+broker]  │  │   │
│  │  │                                                       │  │   │
│  │  │  PodAntiAffinity: 1 broker per node (hard)            │  │   │
│  │  │  Storage: 50Gi local-path PVC per broker              │  │   │
│  │  └──────────────────────────────────────────────────────┘  │   │
│  │                                                             │   │
│  │  ┌──────────────────────────────────────────────────────┐  │   │
│  │  │  Services (auto-created by Strimzi)                   │  │   │
│  │  │  kafka-cluster-kafka-bootstrap  :9092  (PLAIN)        │  │   │
│  │  │  kafka-cluster-kafka-brokers    :9092  (per-broker)   │  │   │
│  │  └──────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              │ bootstrap-servers                    │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Your workloads (any namespace)                              │   │
│  │  bootstrap.servers=kafka-cluster-kafka-bootstrap.kafka       │   │
│  │                   .svc.cluster.local:9092                    │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key design choices:**
- **KRaft mode** (no ZooKeeper) — 3 pods total, simpler topology, fewer images
- **Combined mode** — each pod is both controller and broker
- **Hard PodAntiAffinity** — exactly 1 broker per worker node
- **PLAIN listener only** — WireGuard already encrypts node-to-node traffic
- **Replication factor 3, min ISR 2** — tolerates single broker failure without data loss

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 0 — Prepare Offline Bundle (Online Machine)](#phase-0--prepare-offline-bundle-online-machine)
3. [Phase 1 — Transfer Bundle to Air-Gapped Environment](#phase-1--transfer-bundle-to-air-gapped-environment)
4. [Phase 2 — Install Kafka Cluster (Offline)](#phase-2--install-kafka-cluster-offline)
5. [Phase 3 — Verify Cluster Health](#phase-3--verify-cluster-health)
6. [Connecting Workloads](#connecting-workloads)
7. [Upgrading the Cluster](#upgrading-the-cluster)
8. [Rolling Back the Operator](#rolling-back-the-operator)
9. [Troubleshooting](#troubleshooting)
10. [Full Cleanup](#full-cleanup)
11. [Quick Reference](#quick-reference)

---

## Prerequisites

| Requirement | Details |
|---|---|
| K3s version | **1.25+** — K3s 1.32+ requires Strimzi 0.48.0+ (see [Troubleshooting](#strimzi-operator-crashloopbackoff-on-k3s-132)) |
| K3s cluster | Running, 2+ control plane nodes |
| Worker nodes | **3 nodes minimum** (1 broker per node, hard anti-affinity) |
| Node resources | 2 CPU + 4 GB RAM per worker available for Kafka |
| Storage per broker | 50 GB free disk per worker node (local-path PVC) |
| `kubectl` | Configured and accessible on the control plane |
| `helm` | Version 3.x installed on the cluster |
| Online machine | Docker, Helm, curl, python3 (for Phase 0 only) |

---

## Phase 0 — Prepare Offline Bundle (Online Machine)

Run on a machine with internet access. Output is a single `.tar.gz` to transfer.

```bash
# Clone or copy the kafka_setup/ folder to your online machine
cd kafka_setup/scripts/

# Prepare bundle (auto-detects architecture)
./prepare-kafka-bundle.sh

# Force a specific architecture:
./prepare-kafka-bundle.sh --arch arm64   # Apple Silicon, Raspberry Pi, etc.
./prepare-kafka-bundle.sh --arch amd64   # Intel/AMD servers

# Re-run skipping already-downloaded images:
./prepare-kafka-bundle.sh --skip-images
```

**What it downloads:**
```
kafka-bundle-0.48.0.tar.gz
  └── kafka-bundle-prep/
      ├── images/
      │   ├── strimzi-operator-0.48.0.tar                    (~500 MB)
      │   └── strimzi-kafka-0.48.0-4.0.0.tar                (~700 MB)
      ├── charts/
      │   └── strimzi-kafka-operator-helm-3-chart-0.48.0.tgz (~100 KB)
      └── MANIFEST.env
```

Total bundle size: ~1.1 GB per architecture.

**Custom versions** (environment variable overrides):
```bash
STRIMZI_VERSION=0.48.0 KAFKA_VERSION=4.1.0 ./prepare-kafka-bundle.sh
```

---

## Phase 1 — Transfer Bundle to Air-Gapped Environment

```bash
# Option A — SCP to the control plane node
scp kafka-bundle-0.48.0.tar.gz user@192.168.64.101:/tmp/

# Option B — USB / external media (copy the file, mount on the server)

# On the offline control plane node — extract the bundle
sudo mkdir -p /opt
sudo tar -xzf /tmp/kafka-bundle-0.48.0.tar.gz -C /opt/

# Verify extraction
ls /opt/kafka-bundle-prep/
# Expected: images/  charts/  MANIFEST.env
```

---

## Phase 2 — Install Kafka Cluster (Offline)

Run on the **offline K3s control plane node** (requires root / sudo).

```bash
sudo ./kafka_setup/scripts/install-kafka.sh \
  --bundle-path /opt/kafka-bundle-prep
```

The script performs 8 steps automatically:

| Step | What happens |
|---|---|
| 1 | Load Strimzi images into K3s containerd (`k3s ctr images import`) |
| 2 | Create `kafka` namespace |
| 3 | Install Strimzi operator via Helm (offline chart) |
| 4 | Wait for `strimzi-cluster-operator` deployment to be Ready |
| 5 | Apply `KafkaNodePool` CR (3 replicas, KRaft combined mode, anti-affinity) |
| 6 | Apply `Kafka` CR (KRaft enabled, PLAIN:9092, RF=3, minISR=2) |
| 7 | Wait for Kafka cluster Ready condition |
| 8 | Verify: create test topic, produce/consume message, delete topic |

> **Re-run safety:** The script is idempotent. If it fails mid-way, re-running it resumes from the failed step. Step tracking files are in `/var/log/k3s-install/.steps-kafka/`.
>
> To force a full re-run: `sudo rm -rf /var/log/k3s-install/.steps-kafka/`

**Optional arguments:**
```bash
sudo ./install-kafka.sh --bundle-path /opt/kafka-bundle-prep
sudo ./install-kafka.sh --bundle-path /mnt/usb/kafka-bundle-prep --namespace kafka
sudo ./install-kafka.sh --kubeconfig /path/to/kubeconfig
```

---

## Phase 3 — Verify Cluster Health

```bash
# Check all pods are Running
kubectl get pods -n kafka

# Expected output:
# NAME                                  READY   STATUS    RESTARTS   AGE
# strimzi-cluster-operator-xxx-yyy      1/1     Running   0          5m
# kafka-cluster-kafka-0                 1/1     Running   0          3m
# kafka-cluster-kafka-1                 1/1     Running   0          3m
# kafka-cluster-kafka-2                 1/1     Running   0          3m
# kafka-cluster-entity-operator-xxx     2/2     Running   0          2m

# Check Kafka cluster status
kubectl get kafka kafka-cluster -n kafka

# Check PVCs (should be Bound on each worker node)
kubectl get pvc -n kafka

# Check which node each broker is on (confirm anti-affinity)
kubectl get pods -n kafka -o wide | grep kafka-cluster-kafka
```

---

## Connecting Workloads

Any pod running on this K3s cluster can connect to Kafka using the bootstrap address:

```
kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
```

### Java / Spring Boot

```properties
spring.kafka.bootstrap-servers=kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
```

### Python (confluent-kafka / kafka-python)

```python
from confluent_kafka import Producer, Consumer

producer = Producer({
    'bootstrap.servers': 'kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092'
})

consumer = Consumer({
    'bootstrap.servers': 'kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092',
    'group.id': 'my-group',
    'auto.offset.reset': 'earliest'
})
```

### Kafka CLI (from inside the cluster)

```bash
# Run a temporary pod with Kafka CLI tools
kubectl run kafka-cli --rm -it --image=quay.io/strimzi/kafka:0.48.0-kafka-4.0.0 \
  -n kafka --restart=Never -- bash

# Inside the pod:
/opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --list
```

### Kubernetes ConfigMap pattern (recommended for apps)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-config
data:
  bootstrap.servers: "kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
```

---

## Upgrading the Cluster

Upgrade the Strimzi operator and Kafka version on an offline cluster using a **delta bundle** — only the new images and Helm chart (~500 MB), not a full re-download.

### Step 1 — Prepare upgrade bundle (online machine)

```bash
cd kafka_setup/scripts/

./prepare-kafka-upgrade-bundle.sh \
  --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
  --from-kafka   4.0.0  --to-kafka   4.1.0

# Optional: operator-only upgrade (same Kafka version)
./prepare-kafka-upgrade-bundle.sh \
  --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
  --from-kafka 4.0.0 --to-kafka 4.0.0

# Optional: force target architecture
./prepare-kafka-upgrade-bundle.sh \
  --from-strimzi 0.48.0 --to-strimzi 0.49.0 \
  --from-kafka 4.0.0 --to-kafka 4.1.0 \
  --arch arm64
```

**Output:** `kafka-upgrade-0.48.0-to-0.49.0.tar.gz`

```
kafka-upgrade-0.48.0-to-0.49.0/
  ├── images/
  │   ├── new-strimzi-operator-0.49.0.tar           (~200 MB)
  │   └── new-strimzi-kafka-0.49.0-4.1.0.tar        (~300 MB)
  ├── charts/
  │   └── strimzi-kafka-operator-helm-3-chart-0.49.0.tgz
  └── UPGRADE-MANIFEST.env
```

### Step 2 — Transfer bundle

```bash
# SCP to control plane
scp kafka-upgrade-0.48.0-to-0.49.0.tar.gz user@<node-ip>:/tmp/

# On the offline cluster
sudo tar -xzf /tmp/kafka-upgrade-0.48.0-to-0.49.0.tar.gz -C /opt/
```

### Step 3 — Run upgrade (offline cluster)

```bash
# Dry run first — print the plan without touching the cluster
sudo ./kafka_setup/scripts/upgrade-kafka.sh \
  --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0 \
  --dry-run

# Execute upgrade
sudo ./kafka_setup/scripts/upgrade-kafka.sh \
  --bundle-path /opt/kafka-upgrade-0.48.0-to-0.49.0
```

The upgrade script performs these steps:

| Step | What happens |
|---|---|
| 1 | Validate bundle files and version alignment with running cluster |
| 2 | **Snapshot** current state to `/var/log/k3s-install/kafka-snapshots/<timestamp>/` |
| 3 | Load new images into K3s containerd |
| 4 | `helm upgrade` Strimzi operator → wait Ready (120s) |
| 5 | Patch Kafka CR `version` + `metadataVersion` → rolling broker restart (if needed) |
| 6 | Wait for Kafka CR Ready (600s) |
| 7 | Verify: produce/consume test message |

> **Re-run safety:** Steps are tracked in `/var/log/k3s-install/.steps-kafka-upgrade/`.
> Re-running after a failure resumes from the failed step.

**Flags:**
```bash
--skip-kafka-version-upgrade   # Upgrade operator only, do not patch Kafka CR
--metadata-version 4.1-IV3     # Override if built-in metadataVersion map is outdated
```

**Known metadataVersion values:**

| Kafka | metadataVersion |
|---|---|
| 4.0.0 | `4.0-IV0` |
| 4.1.0 | `4.1-IV3` |

> **Note — entity-operator image after upgrade:** After a successful upgrade you may see the `kafka-cluster-entity-operator` pod still reporting the previous Strimzi operator image (e.g. `operator:0.48.0` even after upgrading to Strimzi 0.49.0). This is expected — Strimzi versions the cluster operator and entity-operator images independently across releases. Verify the upgrade succeeded by checking the Kafka CR status (`kubectl get kafka kafka-cluster -n kafka -o yaml | grep -A10 'status:'`) rather than the entity-operator pod image.

---

## Rolling Back the Operator

> **Data safety:** This rolls back the **Strimzi operator only**. Kafka broker version and topic data are **never modified**. Kafka does not support broker version downgrade once data is written in the new format.

A snapshot is taken automatically before each upgrade. Use its path with `rollback-kafka.sh`.

```bash
# List available snapshots (newest first)
ls -lt /var/log/k3s-install/kafka-snapshots/

# Preview rollback plan (no changes made)
sudo ./kafka_setup/scripts/rollback-kafka.sh \
  --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z

# Execute rollback (prompts for confirmation)
sudo ./kafka_setup/scripts/rollback-kafka.sh \
  --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z

# Skip confirmation prompt (automation)
sudo ./kafka_setup/scripts/rollback-kafka.sh \
  --snapshot-dir /var/log/k3s-install/kafka-snapshots/20260712T100000Z \
  --force
```

**What rollback does:**

| Action | Detail |
|---|---|
| `helm rollback` operator | Restores previous operator chart revision from snapshot |
| Wait operator Ready | 120s timeout |
| Restore `metadataVersion` | Patches Kafka CR back to the snapshot value |
| Wait Kafka CR stable | 300s timeout, verifies broker pods Running |
| **Does NOT change** | `spec.kafka.version` (broker version) — data preserved |

**When to rollback vs full cleanup:**

| Situation | Action |
|---|---|
| Upgrade failed, cluster still has data | `rollback-kafka.sh` (data-safe) |
| Full re-install needed, data can be lost | `cleanup-kafka.sh --force` then reinstall |

---

## Troubleshooting

### Broker pods stuck in Pending

**Symptom:** `kubectl get pods -n kafka` shows `kafka-cluster-kafka-*` in `Pending`.

**Cause:** PodAntiAffinity requires 1 broker per node, but fewer than 3 schedulable worker nodes are available (e.g., a node is cordoned or not Ready).

```bash
# Check node status
kubectl get nodes

# Check scheduling events on the pending pod
kubectl describe pod kafka-cluster-kafka-0 -n kafka | grep -A10 Events
```

**Fix:** Ensure all 3 worker nodes are Ready and not cordoned. If you need to reduce to 2 brokers, edit the KafkaNodePool replicas (but HA guarantees are weakened).

---

### PVC stuck in Pending

**Symptom:** `kubectl get pvc -n kafka` shows PVCs in `Pending`.

**Cause:** `local-path` StorageClass may not be installed, or the node has insufficient disk.

```bash
# Check StorageClass
kubectl get storageclass

# Check PVC events
kubectl describe pvc -n kafka
```

**Fix:** Ensure the K3s `local-path` provisioner is running:
```bash
kubectl get pods -n kube-system | grep local-path
```

---

### KRaft quorum not forming

**Symptom:** Kafka pods are Running but the Kafka CR shows `Ready: False` with a message about controller quorum.

**Cause:** All 3 controller pods must be running for the KRaft quorum (majority = 2 of 3). If a pod is restarting, the quorum is broken.

```bash
# Check Strimzi operator logs for details
kubectl logs -n kafka -l name=strimzi-cluster-operator --tail=100

# Check individual broker logs
kubectl logs kafka-cluster-kafka-0 -n kafka --tail=50
```

---

### Image not found in containerd

**Symptom:** Strimzi operator pod shows `ErrImageNeverPull` or `ImagePullBackOff`.

**Cause:** Images were not imported into containerd, or were imported but tagged differently.

```bash
# Verify images are present in containerd
sudo k3s ctr --namespace k8s.io images list | grep strimzi

# Re-run image loading step
sudo rm /var/log/k3s-install/.steps-kafka/images-loaded
sudo ./kafka_setup/scripts/install-kafka.sh --bundle-path /opt/kafka-bundle-prep
```

---

### Strimzi operator fails to start

**Symptom:** `strimzi-cluster-operator` deployment does not reach Ready.

```bash
# Check operator pod events
kubectl describe pod -n kafka -l name=strimzi-cluster-operator

# Check operator logs (look for Caused by: lines)
kubectl logs -n kafka -l name=strimzi-cluster-operator 2>&1 | grep -A3 "Caused by"
```

---

### Strimzi operator CrashLoopBackOff on K3s 1.32+

**Symptom:** `strimzi-cluster-operator` enters CrashLoopBackOff immediately. Logs show:

```
ERROR PlatformFeaturesAvailability - Detection of Kubernetes version failed.
Caused by: UnrecognizedPropertyException: Unrecognized field "emulationMajor"
           (class io.fabric8.kubernetes.client.VersionInfo)
```

**Cause:** K3s 1.32 added the `emulationMajor` field to its `/version` API response.
Strimzi 0.45.x and 0.46.x use Fabric8 6.13.4 which doesn't recognise this field and crashes on startup.

**Fix:** Use Strimzi **0.48.0+** which ships with a Fabric8 client that handles the new field.
Re-prepare the bundle with the correct versions:

```bash
# On the online machine
STRIMZI_VERSION=0.48.0 KAFKA_VERSION=4.0.0 ./kafka_setup/scripts/prepare-kafka-bundle.sh

# Clean up the broken install first (see Cleanup / Rollback section)
sudo ./kafka_setup/scripts/cleanup-kafka.sh --force

# Reinstall with the new bundle
sudo ./kafka_setup/scripts/install-kafka.sh --bundle-path /opt/kafka-bundle-prep
```

> **Note:** Strimzi 0.48.0 ships Kafka 4.0.0 and 4.1.0 only. Kafka 3.9.x is not available
> in any Strimzi version that supports K3s 1.32+.

---

## Full Cleanup

Use `cleanup-kafka.sh` to fully remove all Strimzi and Kafka resources from the cluster. Safe to run after a partial or failed install.

```bash
# Interactive — prompts for confirmation
sudo ./kafka_setup/scripts/cleanup-kafka.sh

# Non-interactive (CI / automation)
sudo ./kafka_setup/scripts/cleanup-kafka.sh --force
```

**What it removes:**

| Resource | How removed |
|---|---|
| Strimzi CRs (Kafka, KafkaNodePool, Topics…) | Finalizers patched out, then deleted |
| Strimzi operator Helm release | `helm uninstall` |
| All PVCs in `kafka` namespace | `kubectl delete pvc --all` (data loss) |
| `kafka` namespace | `kubectl delete namespace` |
| Strimzi CRDs (cluster-scoped) | `kubectl delete crd -l app=strimzi` |
| Strimzi ClusterRoles / ClusterRoleBindings | Deleted by label |
| Step tracking files | `rm -rf /var/log/k3s-install/.steps-kafka/` |

> **Why finalizer removal first?** When the operator is in CrashLoopBackOff,
> it cannot process finalizer callbacks. Without patching finalizers out,
> Kafka CRs get stuck in `Terminating` indefinitely.

After cleanup, reinstall with:
```bash
sudo ./kafka_setup/scripts/install-kafka.sh --bundle-path /opt/kafka-bundle-prep
```

---

## Quick Reference

```bash
# ── Cluster health ──────────────────────────────────────────────────────────

# All Kafka pods
kubectl get pods -n kafka

# Kafka cluster CR status
kubectl get kafka kafka-cluster -n kafka

# PVC status (should be Bound)
kubectl get pvc -n kafka

# ── Topic management ─────────────────────────────────────────────────────────

BROKER=kafka-cluster-kafka-0
NS=kafka
BS=kafka-cluster-kafka-bootstrap:9092

# List topics
kubectl exec $BROKER -n $NS -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server $BS --list

# Create topic
kubectl exec $BROKER -n $NS -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server $BS --create --topic my-topic --partitions 3 --replication-factor 3

# Describe topic
kubectl exec $BROKER -n $NS -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server $BS --describe --topic my-topic

# Delete topic
kubectl exec $BROKER -n $NS -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server $BS --delete --topic my-topic

# ── Produce / Consume ────────────────────────────────────────────────────────

# Produce (type messages, Ctrl+C to stop)
kubectl exec -it $BROKER -n $NS -- /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server $BS --topic my-topic

# Consume from beginning
kubectl exec $BROKER -n $NS -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server $BS --topic my-topic --from-beginning

# ── Logs ─────────────────────────────────────────────────────────────────────

# Strimzi operator logs
kubectl logs -n $NS -l name=strimzi-cluster-operator -f

# Broker logs
kubectl logs kafka-cluster-kafka-0 -n $NS -f

# Installation log
sudo tail -f /var/log/k3s-install/kafka-install.log

# ── Cleanup / Rollback ───────────────────────────────────────────────────────

# Full cleanup (handles finalizers, CRDs, ClusterRoles, PVCs)
sudo ./kafka_setup/scripts/cleanup-kafka.sh --force
```
