# Networking — Gateway API, routing, and topology

## Full topology

```
Internet / External client
          │
          ▼
  ┌────────────────────────────────────────────────────┐
  │  Traefik (namespace: kube-system)                  │
  │  Service type: LoadBalancer                        │
  │  External: 80→8000 (HTTP), 443→8443 (HTTPS, TBD)   │
  │  Controller: traefik.io/gateway-controller         │
  └───────────────────┬────────────────────────────────┘
                      │  implements
                      ▼
  ┌───────────────────────────────────────────┐
  │  GatewayClass "traefik" (cluster-scoped)  │
  └───────────────────┬───────────────────────┘
                      │  instantiates
                      ▼
  ┌───────────────────────────────────────────┐
  │  Gateway "flipper-gateway"                │
  │  Namespace: game-system                   │
  │  Listener "web": HTTP port 8000           │
  │  (matches Traefik's internal entryPoint)  │
  │  AllowedRoutes: from Same namespace       │
  └──┬──────────────┬────────────┬────────┬───┘
     │              │            │        │
  ┌──▼──────┐ ┌────▼────┐ ┌────▼────┐  ┌─▼───────┐
  │HTTPRoute│ │HTTPRoute│ │HTTPRoute│   │HTTPRoute│
  │backend  │ │front-   │ │back-    │   │dmd-     │
  │/api/*   │ │screen   │ │screen   │   │screen   │
  │(path)   │ │(host)   │ │(host)   │   │(host)   │
  └──┬──────┘ └────┬────┘ └────┬────┘   └─┬───────┘
     │             │          │        │
  ┌──▼──────┐ ┌────▼────┐ ┌────▼────┐┌───▼─────┐
  │backend  │ │front-   │ │ back-    ││dmd-     │
  │:8080    │ │screen:80│ │ screen:80││screen   │
  └──┬──────┘ └─────────┘ └──────────┘│:80      │
     │                                └─────────┘
  ┌──▼──────────────┐
  │SQLite PVC (1Gi) │
  │/data/flipper.db │
  └─────────────────┘
```

---

## Gateway API: concepts and how it works

### Why Gateway API and not Ingress?

The Ingress API (`networking.k8s.io/v1`) is in maintenance mode. It no longer evolves. Gateway API is its official successor, backed by the Kubernetes SIG Network. All new features (traffic splitting, header-based routing, URL rewrite, per-route TLS) live in Gateway API.

**Concrete comparison:**

| Capability | Ingress | Gateway API |
|------------|---------|-------------|
| Path-based routing | ✅ | ✅ |
| Host-based routing | ✅ | ✅ |
| TLS termination | ✅ (annotations) | ✅ (native) |
| Header matching | ❌ (vendor annotations) | ✅ native |
| Traffic splitting (canary) | ❌ (annotations) | ✅ native |
| URL rewrite | ❌ (annotations) | ✅ native |
| Separated roles | ❌ | ✅ (3 levels) |

### The 3 Gateway API objects

**GatewayClass** (scope: cluster, managed by the infra team)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
```
Declares that a controller exists capable of managing Gateways. Traefik watches GatewayClasses whose `controllerName` matches its own. **One per controller** in the cluster.

**Gateway** (scope: namespace, managed by the cluster admin)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: flipper-gateway
  namespace: game-system
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      port: 8000        # Traefik's internal "web" entryPoint port
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```
Instantiates a network entry point. The listener port **8000** matches Traefik's internal `web` entryPoint (defined in `values-traefik.yaml`). The LoadBalancer Service maps external port 80 → internal port 8000 — clients connect on port 80, never 8000 directly.

`allowedRoutes.namespaces.from: Same` means only HTTPRoutes from the `game-system` namespace can attach to this Gateway. To allow other namespaces, use `from: All` or `from: Selector` with a `namespaceSelector`.

**HTTPRoute** (scope: namespace, managed by developers)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-route
  namespace: game-system
spec:
  parentRefs:
    - name: flipper-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: backend
          port: 8080
```
Defines routing rules. `parentRefs` specifies which Gateway will handle these routes. Developers can create/modify their routes without touching the Gateway or GatewayClass.

---

## Current routing rules

### Backend route (`/api/*`)

Everything starting with `/api` is routed to the `backend` Service on port 8080. This routing is **path-prefix** based, with no host constraint.

```
GET /api/health      → backend:8080/api/health
POST /api/games      → backend:8080/api/games
GET /api/users/42    → backend:8080/api/users/42
```

### Screen routes (host-based)

Each screen has its own HTTPRoute based on the **hostname**. Routing is done on the HTTP `Host` header, not the path.

| Hostname (prod)               | Hostname (dev)    | Service        | Port |
|-------------------------------|-------------------|----------------|------|
| `front.flipper.example.com`   | `front.localhost` | `front-screen` | 80   |
| `back.flipper.example.com`    | `back.localhost`  | `back-screen`  | 80   |
| `dmd.flipper.example.com`     | `dmd.localhost`   | `dmd-screen`   | 80   |

In dev, `*.localhost` subdomains resolve automatically to `127.0.0.1` in most modern browsers (RFC 6761) — no `/etc/hosts` entry needed.

**No catch-all `/*`:** Unlike an architecture with a single frontend, there is no catch-all route. A request with no matching hostname returns 404 from the Gateway.

---

## Internal communication (pod-to-pod)

Screens use **Vite** (`import.meta.env.VITE_*`). These variables are injected **at image build time**, not at runtime. The Kubernetes internal DNS is not used by screens to reach the backend — they use the public URL defined at build time.

Key Vite variables:
```bash
# Build-time args passed to docker build
VITE_WS_URL=wss://api.flipper.example.com/ws/bridge
VITE_SCREEN_HUB_URL=wss://api.flipper.example.com
```

`backend` resolves to `backend.game-system.svc.cluster.local` for internal services. Flannel (K3s's CNI) routes packets between pods on different nodes via VXLAN.

---

## Traefik: detailed network configuration

```yaml
# values-traefik.yaml
providers:
  kubernetesGateway:
    enabled: true    # Reads GatewayClass/Gateway/HTTPRoute
  kubernetesIngress:
    enabled: false   # Ignores Ingress resources

ports:
  web:
    port: 8000        # Internal container port — gateway.yaml must match this
    exposedPort: 80   # External port on the LoadBalancer Service
    expose:
      default: true
  websecure:
    port: 8443
    exposedPort: 443
    expose:
      default: true

service:
  type: LoadBalancer

logs:
  general:
    level: INFO
  access:
    enabled: true
```

**LoadBalancer service on bare-metal:** K3s includes ServiceLB (formerly Klipper), a controller that implements `type: LoadBalancer` without MetalLB or a cloud provider. It creates DaemonSet pods on nodes that port-forward from the node IP to the service. Result: Traefik is accessible at `<node-ip>:80` and `<node-ip>:443`.

**Port mapping summary:**
```
Client :80  →  LoadBalancer  →  Traefik container :8000 (web entryPoint)  →  backend:8080
Client :443 →  LoadBalancer  →  Traefik container :8443 (websecure)       →  (TBD)
```

---

## What is not yet configured

### TLS / HTTPS

The Gateway listens on HTTP port 80. For HTTPS:

```yaml
# To add in gateway.yaml
listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
        - name: flipper-tls-cert
          kind: Secret
```

The TLS Secret can be provisioned via cert-manager + Let's Encrypt.

### NetworkPolicies

Currently, all pods in `game-system` can talk to each other freely. To restrict, one would add for example:

```yaml
# Allow only the backend to reach postgres (future migration)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-egress-only
  namespace: game-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: backend
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: backend
```

---

## DNS resolution — quick reference

| Service | Full internal DNS | Short DNS (same namespace) |
|---------|------------------|---------------------------|
| Backend | `backend.game-system.svc.cluster.local:8080` | `backend:8080` |
| front-screen | `front-screen.game-system.svc.cluster.local:80` | `front-screen:80` |
| back-screen | `back-screen.game-system.svc.cluster.local:80` | `back-screen:80` |
| dmd-screen | `dmd-screen.game-system.svc.cluster.local:80` | `dmd-screen:80` |
| Grafana | `kube-prom-grafana.monitoring.svc.cluster.local:80` | — |
| Prometheus | `kube-prom-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090` | — |
| Loki | `loki.monitoring.svc.cluster.local:3100` | — |
