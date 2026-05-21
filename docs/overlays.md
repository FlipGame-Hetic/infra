# Kustomize Overlays — Environments

Overlays let you derive per-environment configurations from a common base (`kubernetes/ressources/`) without duplication.

## Structure

```
kubernetes/
├── ressources/                        # base: namespaces, backend (SQLite), front-screen, back-screen, dmd-screen
├── gateway-api/
│   ├── kustomization.yaml             # HTTPRoutes shared across all environments
│   ├── httproute-backend.yaml         # path-prefix /api → backend:8080
│   ├── httproute-front-screen.yaml    # host front.flipper.example.com → front-screen:80
│   ├── httproute-back-screen.yaml     # host back.flipper.example.com  → back-screen:80
│   ├── httproute-dmd-screen.yaml      # host dmd.flipper.example.com   → dmd-screen:80
│   └── traefik/                       # dev & prod — GatewayClass traefik + Gateway
│       ├── gatewayclass.yaml
│       ├── gateway.yaml
│       └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patches/
    │       ├── backend.yaml           # replicas: 1
    │       ├── screens-config.yaml    # VITE_* → *.localhost (documentation only)
    │       └── httproutes.yaml        # hostnames → *.localhost (front/back/dmd.localhost)
    └── prod/
        ├── kustomization.yaml
        └── patches/
            └── screens-config.yaml   # VITE_* → wss://api.flipper.example.com (documentation only)
```

---

## What each overlay overrides

### `overlays/dev/`

| Parameter | Base | Dev |
|-----------|------|-----|
| `gatewayClassName` | traefik | **traefik** (identical — dev/prod parity) |
| `backend` replicas | 1 (base) | **1** (explicit patch) |
| backend image tag | `latest` (local) | **`ghcr.io/flipgame-hetic/backend:main`** |
| front-screen image tag | `latest` (local) | **`ghcr.io/flipgame-hetic/front-screen:main`** |
| back-screen image tag | `latest` (local) | **`ghcr.io/flipgame-hetic/back-screen:main`** |
| dmd-screen image tag | `latest` (local) | **`ghcr.io/flipgame-hetic/dmd-screen:main`** |
| Screen hostnames | `*.flipper.example.com` | **`*.localhost`** |
| `VITE_WS_URL` (build-arg) | — | `ws://localhost/ws/bridge` |
| `VITE_SCREEN_HUB_URL` (build-arg) | — | `ws://localhost` |

### `overlays/prod/`

| Parameter | Base | Prod |
|-----------|------|------|
| `gatewayClassName` | — | **traefik** (GatewayClass explicitly created) |
| backend image tag | `latest` (local) | **`ghcr.io/flipgame-hetic/backend:prod`** |
| screen image tags | `latest` (local) | **`ghcr.io/flipgame-hetic/*:prod`** |
| Screen hostnames | — | `front/back/dmd.flipper.example.com` (inherited) |
| `VITE_WS_URL` (build-arg) | — | `wss://api.flipper.example.com/ws/bridge` |
| `VITE_SCREEN_HUB_URL` (build-arg) | — | `wss://api.flipper.example.com` |

---

## Gateway API — one controller (Traefik)

Both environments (dev and prod) use Traefik as the Gateway API controller. In local dev, Traefik is installed via Helm in a k3d cluster (see `scripts/local-up.sh`). In production, Traefik is installed via Helm on the K3s cluster with `disable: traefik` in the K3s config.

The `traefik` GatewayClass is created explicitly in `gateway-api/traefik/gatewayclass.yaml` (Traefik does not create it automatically with the Gateway API):

```yaml
# gateway-api/traefik/gateway.yaml (dev & prod)
spec:
  gatewayClassName: traefik
```

This parity simplifies debugging: what works in dev works in prod — same router, same behavior.

---

## Commands

### Deploy in dev

```bash
# All-in-one (recommended) — creates k3d cluster + Traefik + deploys app
GHCR_TOKEN=<github-pat> ./scripts/local-up.sh

# Or if the k3d cluster already exists with Traefik installed
kubectl apply -k kubernetes/overlays/dev
```

### Deploy in prod

```bash
kubectl apply -k kubernetes/overlays/prod
```

### Preview what will be applied (dry-run)

```bash
# Show the full manifest rendered by Kustomize without applying anything
kubectl kustomize kubernetes/overlays/dev
kubectl kustomize kubernetes/overlays/prod

# Server-side dry-run (also validates against Kubernetes)
kubectl apply -k kubernetes/overlays/prod --dry-run=server
```

### Deploy a single component

```bash
# Backend only (without gateway or others)
kubectl apply -k kubernetes/ressources/backend/

# HTTPRoutes only (after modifying a route)
kubectl apply -k kubernetes/gateway-api/
```

---

## Adding a new environment

Example: adding a `staging` overlay.

```bash
mkdir -p kubernetes/overlays/staging/patches
```

```yaml
# kubernetes/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../ressources
  - ../../gateway-api
  - ../../gateway-api/traefik

images:
  - name: backend
    newName: ghcr.io/flipgame-hetic/backend
    newTag: staging
  - name: front-screen
    newName: ghcr.io/flipgame-hetic/front-screen
    newTag: staging
  - name: back-screen
    newName: ghcr.io/flipgame-hetic/back-screen
    newTag: staging
  - name: dmd-screen
    newName: ghcr.io/flipgame-hetic/dmd-screen
    newTag: staging

patches:
  - path: patches/backend.yaml
  - path: patches/screens-config.yaml
```

```yaml
# kubernetes/overlays/staging/patches/backend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: game-system
spec:
  replicas: 1
```

```yaml
# kubernetes/overlays/staging/patches/screens-config.yaml
# Documentation only — VITE_* must be passed as --build-arg at image build time.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: front-screen-config
  namespace: game-system
data:
  VITE_WS_URL: "wss://api.staging.flipper.example.com/ws/bridge"
  VITE_SCREEN_HUB_URL: "wss://api.staging.flipper.example.com"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: back-screen-config
  namespace: game-system
data:
  VITE_SCREEN_HUB_URL: "wss://api.staging.flipper.example.com"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dmd-screen-config
  namespace: game-system
data:
  VITE_SCREEN_HUB_URL: "wss://api.staging.flipper.example.com"
```

---

## Kustomize security rules

Kustomize forbids nested kustomizations from referencing files **outside their own directory**. This is why:

- `gateway-api/traefik/` contains its own copies of `gatewayclass.yaml` and `gateway.yaml` (no `../gatewayclass.yaml`).
- HTTPRoutes are in `gateway-api/` (root) and referenced directly by overlays via `../../gateway-api` — only **directories** with a `kustomization.yaml` can be referenced from a parent level, not raw files.
