# Flipper Infrastructure — Documentation

Complete documentation for the Flipper project K3s infrastructure.

## Documentation structure

| File | Content |
|------|---------|
| [architecture.md](architecture.md) | Overview, architecture decisions and their rationale |
| [cluster-setup.md](cluster-setup.md) | K3s cluster installation and configuration |
| [networking.md](networking.md) | Gateway API, HTTP routing, network topology |
| [storage.md](storage.md) | Persistent volumes, storage classes, data strategy |
| [observability.md](observability.md) | Prometheus, Grafana, Loki — metrics and logs |
| [secrets.md](secrets.md) | Secret management, rotation procedures |
| [deployment.md](deployment.md) | Deployment and update procedures |
| [debugging.md](debugging.md) | Debugging guide, useful commands, common scenarios |

## Quick start

### Local dev (k3d)

```bash
# All-in-one: creates the k3d cluster, installs dependencies, deploys the app
./scripts/local-up.sh

# Access after startup:
#   Front screen  → http://front.localhost
#   Back screen   → http://back.localhost
#   DMD screen    → http://dmd.localhost
#   Backend API   → http://localhost:8080/docs
#   Grafana       → http://localhost:3004  (admin / admin)
```

### Production (2-node K3s cluster)

```bash
# 1. Bootstrap the cluster (once)
./scripts/bootstrap.sh <server-ip> [agent-ip...]

# 2. Create application secrets
kubectl create secret generic backend-secret \
  --from-literal=SCREEN_JWT_SECRET=$(openssl rand -base64 32) \
  -n game-system

# 3. Deploy
GRAFANA_PASSWORD=<password> ./scripts/deploy.sh

# 4. Access Grafana
kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring
# → http://localhost:3000 (admin / <GRAFANA_PASSWORD>)
```

## High-level diagram

```
Internet
    │
    ▼
Traefik (LoadBalancer :80/:443)
    │
    ▼
Gateway API (flipper-gateway)
    ├─── /api/*                    ──► Backend     (2–5 pods, HPA CPU 70%)
    │                                   └── SQLite (PVC 1 Gi, /data/flipper.db)
    ├─── front.flipper.example.com ──► front-screen (1 pod)
    ├─── back.flipper.example.com  ──► back-screen  (1 pod)
    └─── dmd.flipper.example.com   ──► dmd-screen   (1 pod)

Namespace monitoring:
  Prometheus (10 Gi, 15d) + Grafana (2 Gi) + Loki (10 Gi)
```
