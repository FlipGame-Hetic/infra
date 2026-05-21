# Deployment — Procedures and updates

## Full deployment flow

```
Bootstrap (once)              Recurring deployment
      │                              │
      ▼                              ▼
bootstrap.sh              1. Create/verify secrets
  - Install K3s            2. GRAFANA_PASSWORD=xxx deploy.sh
  - Gateway API CRDs          - kubectl apply -k ressources/
  - Traefik via Helm          - helm upgrade kube-prom
  - Namespaces                - helm upgrade loki
```

---

## First-time installation

### Step 1 — Bootstrap cluster

```bash
./scripts/bootstrap.sh <server-ip> <agent-ip>
```

See [cluster-setup.md](cluster-setup.md) for the detail of each step.

### Step 2 — Create application secrets

```bash
# JWT secret for screen authentication
kubectl create secret generic backend-secret \
  --from-literal=SCREEN_JWT_SECRET=$(openssl rand -base64 32) \
  -n game-system

# (Optional) GHCR pull secret if images are private
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=flipgame-hetic \
  --docker-password=<github-pat> \
  --namespace=game-system
kubectl patch serviceaccount default -n game-system \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
```

Store the `SCREEN_JWT_SECRET` in a secrets manager (Bitwarden, 1Password…).

### Step 3 — Deploy

```bash
export GRAFANA_PASSWORD=$(openssl rand -base64 16)
./scripts/deploy.sh
```

Store the Grafana password in a secrets manager.

> **Local dev:** Use `./scripts/local-up.sh` instead — this script handles cluster creation (k3d), secrets, and deployment in a single command.

### Step 4 — Verify

```bash
# All pods Running?
kubectl get pods -n game-system
kubectl get pods -n monitoring

# Is the Gateway ready?
kubectl get gateway -n game-system

# Are the routes attached?
kubectl get httproute -n game-system
```

---

## `scripts/deploy.sh`

The script executes 3 operations in order:

### 1. Application resources (Kustomize)

```bash
kubectl apply -k kubernetes/ressources
```

Kustomize reads `kubernetes/ressources/kustomization.yaml`, composes all resources (namespaces + backend + screens + gateway-api), and applies them. This command is **idempotent**: if resources already exist, Kubernetes updates them only if they have changed.

Resources created/updated:
- Namespaces `game-system` and `monitoring`
- Deployments: backend (1 replica base, HPA 2-5 prod), front-screen (1), back-screen (1), dmd-screen (1)
- Services: backend:8080, front-screen:80, back-screen:80, dmd-screen:80
- ConfigMaps: backend-config, front/back/dmd-screen-config (VITE_* documentation)
- HPA: backend (2-5 replicas, CPU 70%)
- PVC: backend-sqlite-pvc (1 Gi)
- Gateway API: GatewayClass traefik, Gateway flipper-gateway, HTTPRoutes backend + front-screen + back-screen + dmd-screen

### 2. kube-prometheus-stack (Helm)

```bash
helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values kubernetes/helm/monitoring/values-prometheus.yaml \
  --set grafana.adminPassword="$GRAFANA_PASSWORD"
```

`upgrade --install`: idempotent — installs if absent, updates if present.

### 3. Loki (Helm)

```bash
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values kubernetes/helm/monitoring/values-loki.yaml
```

---

## Updating an application image

To deploy a new backend version:

```bash
# Option 1: edit the tag in the overlay and apply
# Edit kubernetes/overlays/prod/kustomization.yaml → newTag: "prod"
kubectl apply -k kubernetes/overlays/prod

# Option 2: kubectl set image (without modifying the file)
kubectl set image deployment/backend \
  backend=ghcr.io/flipgame-hetic/backend:prod \
  -n game-system

# Watch the rollout
kubectl rollout status deployment/backend -n game-system
```

**Option 1 is preferred** in production because the git manifest remains the source of truth. Option 2 creates a divergence between what is running and what is in git.

**Updating a screen:** Since Vite variables are baked into the image, any change to `VITE_WS_URL` or `VITE_SCREEN_HUB_URL` requires **rebuilding the image** with the new `--build-arg`, then updating the tag in the overlay.

```bash
docker build \
  --build-arg VITE_WS_URL=wss://api.flipper.example.com/ws/bridge \
  --build-arg VITE_SCREEN_HUB_URL=wss://api.flipper.example.com \
  -t ghcr.io/flipgame-hetic/front-screen:prod .
docker push ghcr.io/flipgame-hetic/front-screen:prod
# Then update the overlay and kubectl apply
```

### Rollout strategy

The backend Deployment uses the `RollingUpdate` strategy (Kubernetes default):
- New pod started → health check OK → old pod stopped.
- Guarantees 0 downtime if the `/health` health check responds correctly.
- Minimum pods available during rollout: 1 (with 2 replicas, never drops to 0).

---

## Rollback

```bash
# View rollout history
kubectl rollout history deployment/backend -n game-system

# Rollback to the previous version
kubectl rollout undo deployment/backend -n game-system

# Rollback to a specific version
kubectl rollout undo deployment/backend -n game-system --to-revision=2
```

---

## Partial deployment (single component)

```bash
# Backend only
kubectl apply -k kubernetes/ressources/backend/

# One screen only
kubectl apply -k kubernetes/ressources/front-screen/
kubectl apply -k kubernetes/ressources/back-screen/
kubectl apply -k kubernetes/ressources/dmd-screen/

# Gateway API only (after modifying routes)
kubectl apply -k kubernetes/gateway-api/

# Namespace only (rarely needed)
kubectl apply -k kubernetes/ressources/namespace/
```

---

## Updating Traefik

```bash
helm upgrade traefik traefik/traefik \
  --namespace kube-system \
  --values kubernetes/helm/ingress/values-traefik.yaml
```

Traefik uses Deployments — the rollout is managed by Helm.

## Updating the monitoring stack

```bash
# Update Prometheus/Grafana
helm repo update
helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values kubernetes/helm/monitoring/values-prometheus.yaml \
  --set grafana.adminPassword="$GRAFANA_PASSWORD"

# Update Loki
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --values kubernetes/helm/monitoring/values-loki.yaml
```

**Note for kube-prometheus-stack:** Major updates may change CRDs (ServiceMonitor, PrometheusRule…). Follow the chart release notes.

---

## Environments (Kustomize overlays)

Two overlays are available:
- **`dev`**: Traefik (via k3d), backend 1 replica, images `:main`, hostnames `*.localhost`
- **`prod`**: Traefik (K3s), backend min 2 replicas (HPA), images `:prod`, hostnames `*.flipper.example.com`

```bash
# Local dev
kubectl apply -k kubernetes/overlays/dev

# Production
kubectl apply -k kubernetes/overlays/prod
```

**Screen note:** Vite images must be built with the correct `--build-arg` (`VITE_WS_URL`, `VITE_SCREEN_HUB_URL`) before deployment. Screen ConfigMaps in the overlays are purely for documentation.

See [overlays.md](overlays.md) for the complete documentation (structure, per-environment differences, adding a new overlay).

---

## `scripts/cleanup.sh`

```bash
./scripts/cleanup.sh
```

The script asks for two confirmations:
1. Delete Kubernetes resources (Helm + Kustomize)
2. Delete Gateway API CRDs (optional, irreversible for objects that use them)

**What cleanup does NOT do:**
- Does not uninstall K3s itself (see [cluster-setup.md](cluster-setup.md#full-uninstall))
- Does not delete PVCs (persisted data) by default
- Does not touch the local kubeconfig

To delete PVCs after cleanup:
```bash
kubectl delete pvc --all -n game-system
kubectl delete pvc --all -n monitoring
```
