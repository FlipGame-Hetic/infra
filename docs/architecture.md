# Architecture — Decisions and rationale

## Overview

The cluster hosts the Flipper project: a backend (Rust / Axum / Tokio), three screen interfaces (Vite / React / ThreeJs: `front-screen`, `back-screen`, `dmd-screen`), and a SQLite database embedded in the backend. The infrastructure is intentionally simple: two K3s nodes, Kustomize for application manifests, Helm only for observability.

---

## Structural decisions

### 1. K3s over vanilla K8s

**Choice:** K3s (lightweight Kubernetes distribution by Rancher).

**Why not vanilla K8s?**
- Vanilla K8s requires a clustered etcd, HA control-plane, and several separate components. For two nodes, that is oversized and expensive to maintain.
- K3s packages everything into a single binary (~70 MB): API server, scheduler, controller-manager, kubelet, kube-proxy, containerd, Flannel (CNI), and a local storage provisioner (`local-path`).
- Startup takes a few minutes versus ~30–60 min for vanilla K8s with kubeadm.

**Consequences:**
- Storage: `local-path` available without installing anything extra.
- Network: Flannel by default (VXLAN); no need for Calico/Cilium on a 2-node cluster.
- Traefik pre-installed (but disabled so we manage it via Helm: see below).

---

### 2. 2-node cluster: 1 server + 1 agent

**Choice:** 1 control-plane node (server) + 1 worker node (agent).

**Why not 1 node?**
A single-node cluster loses all application workload if the node restarts (maintenance, crash). With 2 nodes, pods reschedule to the second node while the first is unavailable.

**Why not 3 nodes?**
3 nodes are needed for etcd HA quorum (fault-tolerant control-plane). That is the right call for critical production, but here:
- The cost triples (3 VPS instead of 1).
- The current load does not justify it.
- The K3s control-plane is on 1 node: if it goes down, scheduling stops but **already-running pods keep running**. For stateless workloads (backend/frontend), this is acceptable.

**Summary:** 2 nodes = application resilience without extra cost. 3 nodes = control-plane resilience, to reconsider if load increases.

---

### 3. Kustomize for application resources

**Choice:** Kustomize (native `kubectl -k`) for backend and screens.

**Why not Helm for everything?**
Helm is powerful but adds an abstraction layer (templates, values, hooks) that complicates debugging. `helm template` produces generated YAML that must be inspected. With Kustomize, what you write is exactly what gets applied.

**Why Helm only for observability?**
The `kube-prometheus-stack` and `loki` charts have dozens of sub-components (Prometheus Operator, CRDs, AlertManager, Grafana, etc.). Managing them as raw YAML would be a substantial effort. Helm is precisely for packaging third-party complexity.

**Rule:** Kustomize for our resources (fully controlled), Helm for complex external stacks.

**Kustomize structure:**
```
kubernetes/ressources/
├── kustomization.yaml        ← root, composes everything
├── namespace/                ← game-system + monitoring
├── backend/                  ← Deployment + Service + ConfigMap + HPA + PVC (SQLite)
├── front-screen/             ← Deployment + Service + ConfigMap (Vite, port 80)
├── back-screen/              ← Deployment + Service + ConfigMap (Vite, port 80)
└── dmd-screen/               ← Deployment + Service + ConfigMap (Vite, port 80)
```

The root `kustomization.yaml` also includes `../gateway-api` (separate because these CRDs have their own lifecycle).

---

### 4. Gateway API over Ingress

**Choice:** Gateway API (gateway.networking.k8s.io/v1).

**Why not Ingress?**
The `networking.k8s.io/v1/Ingress` API has been in **maintenance mode** since Kubernetes 1.19 (announced by SIG Network). No new features will be added. Gateway API is its official successor.

**Concrete advantages of Gateway API:**
- Role separation: `GatewayClass` (infra-team), `Gateway` (cluster-admin), `HTTPRoute` (dev-team). Each team manages its own scope.
- Native support for advanced features: traffic splitting, header matching, URL rewrite, per-route TLS termination.
- Supported by all modern controllers (Traefik, Cilium, Envoy Gateway, etc.).

**Required configuration:**
```yaml
# /etc/rancher/k3s/config.yaml
kube-apiserver-arg:
  - 'feature-gates=GatewayAPI=true'
```
K3s does not enable Gateway API by default. Without this flag, `kubectl apply` on a `Gateway` fails with "no kind GatewayClass is registered".

**Current routing:**
- `/api/*` → Backend:8080 (path-prefix, all routes)
- `front.flipper.example.com` → front-screen:80 (host-based)
- `back.flipper.example.com` → back-screen:80 (host-based)
- `dmd.flipper.example.com` → dmd-screen:80 (host-based)

---

### 5. Traefik disabled by K3s, managed via Helm

**Why disable K3s's bundled Traefik?**
K3s installs Traefik automatically but at a fixed version. Managing it via Helm lets us choose the version, configure values precisely, and enable `kubernetesGateway` (Gateway API support) that the bundled version does not guarantee.

```yaml
# values-traefik.yaml — key settings
providers:
  kubernetesGateway:
    enabled: true    # Enable Gateway API support
  kubernetesIngress:
    enabled: false   # Ignore Ingress resources
service:
  type: LoadBalancer # Expose on the node IP (bare-metal)
```

`service.type: LoadBalancer` works on K3s thanks to the built-in ServiceLB controller (Klipper) — no MetalLB needed.

**Traefik in local dev:** The dev overlay also uses Traefik (via Helm in k3d), not nginx-gateway-fabric. Both environments share the same Gateway API controller, which simplifies dev/prod parity.

---

### 6. Two namespaces

**`game-system`**: all application workloads (backend, front-screen, back-screen, dmd-screen). Clear isolation between "our app" and "observation infrastructure".

**`monitoring`**: Prometheus, Grafana, Loki. Separated to:
- Grant different RBAC rights (devs see `game-system`, ops sees `monitoring`).
- Avoid Prometheus CRD verbosity (ServiceMonitor, PrometheusRule, etc.) polluting the application namespace.
- Allow deleting/recreating monitoring without touching the app.

---

### 7. SQLite as the database

**Choice:** SQLite embedded in the backend, file `/data/flipper.db` mounted via a `backend-sqlite-pvc` PVC (1 Gi).

**Why not PostgreSQL?**
For the current load (1–5 backend pods, moderate usage), SQLite is sufficient and removes an entire component to operate: no postgres StatefulSet, no `POSTGRES_PASSWORD` secret, no additional failure point.

**How data persists:**
The `backend-sqlite-pvc` PVC (`local-path`, 1 Gi, `ReadWriteOnce`) is mounted at `/data` in the backend container. SQLite writes to this directory. The file survives pod restarts.

```yaml
# backend/pvc.yaml
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

**Known limitation:** `ReadWriteOnce` + SQLite = only the pod scheduled on the same node as the PVC can write. The HPA is configured (min 2 replicas), but in practice **only one backend pod writes to SQLite**. If the load genuinely requires concurrent replicas, migrating to PostgreSQL or a distributed CSI (Longhorn + ReadWriteMany) will be necessary.

---

### 8. HPA on backend only

**Backend: HPA with 70% CPU target, 2–5 replicas.**
- The backend handles API requests that can vary in load. CPU autoscaling is simple and effective for stateless workloads.
- Min 2 replicas: availability even during a rollout (one pod always stays up).
- Max 5 replicas: guardrail to avoid saturating a 2-node cluster.
- **SQLite + HPA caveat:** The `backend-sqlite-pvc` is `ReadWriteOnce`. Multiple replicas can start but only one writes to SQLite — see decision 7.

**Screens (`front-screen`, `back-screen`, `dmd-screen`): 1 fixed replica, no HPA.**
- Vite screens serve pre-compiled static HTML/CSS/JS. Load is low and predictable.
- 1 replica is enough; adding an HPA would add complexity without real value.

### 9. Vite variables — build-time only

Screens use Vite which injects `VITE_*` variables at compile time (via `import.meta.env`). These values are **baked into the image binary**. The ConfigMaps `front-screen-config`, `back-screen-config`, `dmd-screen-config` exist in the manifests for documentation purposes only — they are **not** mounted into containers.

**CI consequence:** Changing `VITE_WS_URL` or `VITE_SCREEN_HUB_URL` requires rebuilding and repushing images with the correct `--build-arg`:
```bash
docker build \
  --build-arg VITE_WS_URL=wss://api.flipper.example.com/ws/bridge \
  --build-arg VITE_SCREEN_HUB_URL=wss://api.flipper.example.com \
  -t ghcr.io/flipgame-hetic/front-screen:prod .
```

---

### 10. `local-path` storage

**Why not a cloud CSI (EBS, GCE PD, etc.)?**
This cluster runs on bare-metal VPS (or physical servers). Cloud CSIs only work on cloud provider VMs. `local-path` is the native K3s provisioner that creates directories on the node's disk.

**Limitation:** Data is tied to the node. If the node disappears, the data does too. For true HA storage, Longhorn (or Rook/Ceph) would replicate volumes between nodes.

**Why acceptable here?**
- SQLite: regular backups are sufficient for moderate load.
- Prometheus/Loki: metrics and logs have decreasing value over time.
- Grafana: dashboards can be version-controlled (Dashboard as Code with Grafonnet or JSON in git).

---

## What is not done yet

| Item | Status | Priority |
|------|--------|----------|
| TLS / HTTPS on the Gateway | Not configured | High |
| Sealed Secrets or External Secrets | Not configured | High |
| SQLite → PostgreSQL migration (if load increases) | Not planned | Medium |
| Longhorn (HA storage) | Not configured | Medium |
| NetworkPolicies | Not configured | Medium |
| Terraform (VPS provisioning) | Mentioned, not implemented | Low |
