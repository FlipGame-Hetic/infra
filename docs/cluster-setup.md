# Cluster installation and configuration

## Prerequisites

| Tool | Minimum version | Usage |
|------|----------------|-------|
| `kubectl` | ≥ 1.28 | Cluster management |
| `helm` | ≥ 3.12 | Observability stack installation |
| `k3d` | ≥ 5.0 | Local cluster (dev only) |
| `docker` | — | Required by k3d |
| SSH | — | Node access (prod) |
| Bash | ≥ 4.0 | Running scripts |

> **Local dev:** `./scripts/install-deps.sh` automatically installs any missing tools (kubectl, helm, k3d, docker). `./scripts/local-up.sh` then handles everything else.

Nodes must:
- Have fixed IPs reachable between each other (port 6443 must be open between server and agents).
- Run Linux (Debian/Ubuntu recommended).
- Have a minimum of 2 GB RAM per node (4 GB recommended for the server node).

---

## Bootstrap: `scripts/bootstrap.sh`

The script handles the full installation from scratch.

```bash
./scripts/bootstrap.sh <server-ip> [agent-ip-1] [agent-ip-2] ...
```

**Example for 2 nodes:**
```bash
./scripts/bootstrap.sh 192.168.1.10 192.168.1.11
```

### What the script does, step by step

#### Step 1 — K3s server configuration

The script creates `/etc/rancher/k3s/config.yaml` on the server:

```yaml
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - feature-gates=GatewayAPI=true
disable:
  - traefik
```

**`write-kubeconfig-mode: "0644"`**: Without this, the kubeconfig file is 0600 and owned by root. This makes it readable by the current user.

**`feature-gates=GatewayAPI=true`**: Kubernetes does not recognize Gateway API types by default. This flag enables their support at the API server level. Without it, `kubectl apply` on a `Gateway` fails with "no kind GatewayClass is registered".

**`disable: traefik`**: K3s installs Traefik automatically. We disable it here to manage it ourselves via Helm (see [architecture.md](architecture.md#5-traefik-disabled-by-k3s-managed-via-helm)).

Then K3s is installed via the official script:
```bash
curl -sfL https://get.k3s.io | sh -
```

The script waits for the node to reach `Ready` before continuing.

#### Step 2 — Adding agents (workers)

For each agent IP provided, the script:
1. Retrieves the K3s token from the server: `/var/lib/rancher/k3s/server/node-token`
2. Installs K3s in agent mode on the worker:
   ```bash
   K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> curl -sfL https://get.k3s.io | sh -
   ```

Port **6443** is the K3s API server (equivalent to kube-apiserver).

#### Step 3 — Local kubeconfig

```bash
scp root@<server-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/<server-ip>/' ~/.kube/config
chmod 600 ~/.kube/config
```

K3s writes the kubeconfig with `127.0.0.1` as the cluster address. We replace it with the actual server IP to control the cluster from our local machine.

#### Step 4 — Gateway API CRDs

```bash
kubectl apply --server-side=true \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.05/monthly-2026.05-install.yaml
```

**`--server-side=true`**: Gateway API CRDs are very large YAML objects (>256 KB of annotations). Client-side `apply` has a size limit on `last-applied-configuration` annotations. Server-side apply bypasses this limit by delegating field management to the server.

Installed CRDs include: `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `TCPRoute`, etc.

#### Step 5 — Traefik via Helm

```bash
helm repo add traefik https://helm.traefik.io/traefik
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --values kubernetes/helm/ingress/values-traefik.yaml
```

`upgrade --install`: creates if absent, updates if present. Idempotent.

#### Step 6 — Namespaces

```bash
kubectl apply -k kubernetes/ressources/namespace/
```

Creates `game-system` and `monitoring` before any application resources.

#### Step 7 — Application secrets

```bash
kubectl create secret generic backend-secret \
  --from-literal=SCREEN_JWT_SECRET=$(openssl rand -base64 32) \
  -n game-system
```

Store the generated secret in a secrets manager. Without this secret, the backend pod stays in `CreateContainerConfigError`.

---

## Post-bootstrap checks

```bash
# All nodes Ready?
kubectl get nodes

# Traefik deployed?
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik

# Gateway API CRDs present?
kubectl get crd gateways.gateway.networking.k8s.io

# Namespaces created?
kubectl get namespaces | grep -E 'game-system|monitoring'
```

Expected output:
```
NAME           STATUS   AGE
game-system    Active   1m
monitoring     Active   1m
```

---

## Detailed K3s configuration

### Server config file (`/etc/rancher/k3s/config.yaml`)

This file is read at K3s startup. Equivalent to flags passed to `k3s server`.

```yaml
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - feature-gates=GatewayAPI=true
disable:
  - traefik
```

**Other useful options** (not configured but documented):

```yaml
# Change the pod CIDR (default: 10.42.0.0/16)
cluster-cidr: "10.42.0.0/16"

# Change the service CIDR (default: 10.43.0.0/16)
service-cidr: "10.43.0.0/16"

# Enable audit logging
kube-apiserver-arg:
  - audit-log-path=/var/log/k3s-audit.log
  - audit-log-maxage=30

# Disable the built-in NetworkPolicy controller (if using Cilium)
disable-network-policy: true
```

### Internal DNS

K3s installs CoreDNS for internal DNS resolution. Each Service is resolvable via:
```
<service>.<namespace>.svc.cluster.local
```

Examples:
- `backend.game-system.svc.cluster.local:8080`
- `front-screen.game-system.svc.cluster.local:80`
- `kube-prom-grafana.monitoring.svc.cluster.local:80`

Within the same namespace, the short name suffices: `backend`, `front-screen`, `back-screen`, `dmd-screen`.

---

## Updating K3s

```bash
# On the server first
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.0+k3s1 sh -

# Then on each agent
K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> \
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.0+k3s1 sh -
```

Always update the server first, then the agents.

---

## Full uninstall

The `scripts/cleanup.sh` script removes Kubernetes resources. To uninstall K3s itself:

```bash
# On the server
/usr/local/bin/k3s-uninstall.sh

# On each agent
/usr/local/bin/k3s-agent-uninstall.sh
```

These scripts are installed automatically by K3s. They stop the service, remove binaries, and clean up network interfaces and iptables rules.
