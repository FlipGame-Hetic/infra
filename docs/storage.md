# Storage — Persistent volumes and data strategy

## Overview

All volumes use the `local-path` StorageClass, the native K3s provisioner. No external CSI, no Longhorn, no cloud provider.

| Component | PVC | Size | Node-bound |
|-----------|-----|------|------------|
| Backend (SQLite) | `backend-sqlite-pvc` | 1 Gi | Yes (node where the pod is scheduled) |
| Prometheus | auto-created by Helm | 10 Gi | Yes |
| Grafana | auto-created by Helm | 2 Gi | Yes |
| Loki | auto-created by Helm | 10 Gi | Yes |

**Total:** 23 Gi minimum on node disks.

---

## StorageClass `local-path`

`local-path` is installed by K3s at bootstrap. It creates PersistentVolumes by mounting subdirectories under `/var/lib/rancher/k3s/storage/` on the node.

```bash
# Check the StorageClass
kubectl get storageclass

# Expected output
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   5d
```

**`VOLUMEBINDINGMODE: WaitForFirstConsumer`**: The PV is not created immediately when the PVC is created. It waits for a pod to request that PVC, and creates the volume on the **node where the pod is scheduled**. This guarantees that the pod and its volume are always on the same node.

**`RECLAIMPOLICY: Delete`**: When a PVC is deleted, the PV and the data on disk are deleted. Unlike `Retain`, which keeps the data and leaves it to the admin to recover.

---

## Backend SQLite — `backend-sqlite-pvc`

### Definition

```yaml
# backend/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backend-sqlite-pvc
  namespace: game-system
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

**`ReadWriteOnce`**: The volume can only be mounted by one pod at a time in read/write mode. SQLite is not designed for concurrent multi-process access from different pods.

### Mounting in the Deployment

```yaml
# backend/deployment.yaml
containers:
  - name: backend
    volumeMounts:
      - name: sqlite-data
        mountPath: /data
volumes:
  - name: sqlite-data
    persistentVolumeClaim:
      claimName: backend-sqlite-pvc
```

The env variable `DATABASE_URL: "sqlite:////data/flipper.db"` (in the backend ConfigMap) points to this file.

### Implications of local-path for SQLite

**The backend pod is tied to the node where the PVC was first created.** If that node becomes unavailable, Kubernetes cannot reschedule the backend pod to the other node — the `local-path` PVC is physically tied to the original node's disk.

Behavior during a node failure:
1. The backend pod stays in `Pending`.
2. The API is unavailable until the node comes back.

**HPA and SQLite:** The HPA can create multiple backend pods, but only the one scheduled on the PVC's node can mount the volume in `ReadWriteOnce` mode. Other pods will remain in `Pending` on this mount point.

**If this limitation becomes a problem:** migrate to PostgreSQL (StatefulSet with replication) or Longhorn (distributed CSI + `ReadWriteMany`).

---

## Prometheus — metrics storage

```yaml
# values-prometheus.yaml
prometheusSpec:
  retention: 15d
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: local-path
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 10Gi
```

**15-day retention:** Compromise between historical metrics availability and disk space. For a 2-node cluster with few services, 10 Gi for 15 days is more than enough. Prometheus automatically compresses TSDB data.

The PVC is named automatically by Helm with a `prometheus-kube-prom-...` prefix. To find it:
```bash
kubectl get pvc -n monitoring
```

---

## Grafana — dashboards and settings

```yaml
# values-prometheus.yaml
grafana:
  persistence:
    enabled: true
    storageClassName: local-path
    size: 2Gi
```

Grafana stores in its volume:
- Dashboards created manually through the UI
- Datasources configured through the UI
- Annotations, playlists, UI alerts

**Warning:** Dashboards created via the UI are not version-controlled in git. If the PVC is lost, manual dashboards are lost too. Best practice: export dashboards as JSON and commit them to `kubernetes/helm/monitoring/dashboards/`.

---

## Loki — application logs

```yaml
# values-loki.yaml
singleBinary:
  persistence:
    enabled: true
    storageClass: local-path
    size: 10Gi

loki:
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
```

**`SingleBinary` mode**: Loki can be deployed in distributed mode (separate components: querier, ingester, distributor…) but for a 2-node cluster, a single pod is sufficient. This simplifies operations considerably.

**`store: tsdb`**: The log indexing engine. TSDB (Time Series Database) is recommended since Loki v2.8. More performant than BoltDB (the former default).

**`period: 24h`**: Indexes are created in 24h periods. Each day produces a new index file. This simplifies archiving or deleting old data.

**Loki retention:** Configured to **15 days** in `values-loki.yaml`:
```yaml
loki:
  limits_config:
    retention_period: 15d
  compactor:
    retention_enabled: true
    delete_request_store: filesystem  # Required in Loki 3.x
```
Logs older than 15 days are automatically deleted by the compactor.

---

## Checking storage state

```bash
# List all PVCs and their status
kubectl get pvc -A

# Detail on the backend SQLite PVC
kubectl describe pvc backend-sqlite-pvc -n game-system

# Space used on nodes (SSH onto the node)
du -sh /var/lib/rancher/k3s/storage/

# See created PVs
kubectl get pv
```

Typical `kubectl get pvc -A` output:
```
NAMESPACE     NAME                   STATUS   VOLUME          CAPACITY   ACCESS MODES   STORAGECLASS   AGE
game-system   backend-sqlite-pvc     Bound    pvc-abc123...   1Gi        RWO            local-path     5d
monitoring    prometheus-kube-...    Bound    pvc-def456...   10Gi       RWO            local-path     5d
monitoring    grafana-kube-...       Bound    pvc-ghi789...   2Gi        RWO            local-path     5d
monitoring    loki-...               Bound    pvc-jkl012...   10Gi       RWO            local-path     5d
```

A PVC in `Pending` means the provisioner could not create the volume (insufficient disk space, or pod not yet scheduled if WaitForFirstConsumer).

---

## SQLite backup

No automated backup configured. For a manual backup:

```bash
# Copy the SQLite file from the backend pod
kubectl exec -n game-system deployment/backend -- \
  cp /data/flipper.db /tmp/flipper-backup-$(date +%Y%m%d).db

kubectl cp game-system/<backend-pod-name>:/tmp/flipper-backup-$(date +%Y%m%d).db ./flipper-backup.db
```

For automated backups, consider:
- A Kubernetes CronJob that copies the SQLite file + uploads to S3/Minio (or `litestream` for continuous streaming replication).
- Velero for full cluster snapshots (PVCs included).
