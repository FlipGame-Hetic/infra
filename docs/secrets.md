# Secrets — Management and procedures

## Current state

Application secrets in the `game-system` namespace:

| Secret | Key | Used by | Notes |
|--------|-----|---------|-------|
| `backend-secret` | `SCREEN_JWT_SECRET` | backend Deployment | JWT for screen authentication |
| `ghcr-pull-secret` | *(docker registry)* | all pods | Pull private images from `ghcr.io/flipgame-hetic/` |
| `postgres-secret` | `POSTGRES_PASSWORD` | *nothing* | **Stale artifact** — created by `local-up.sh` but not referenced by any manifest (PostgreSQL was removed) |

**These secrets are not defined in YAML manifests** — they must be created manually or via CI/CD before deployment. The `local-up.sh` script creates them automatically for local dev.

> **`postgres-secret` is a known stale artifact** in `local-up.sh`. It does not affect any running workload but should be removed from the script in a future cleanup.

---

## Creating `backend-secret`

```bash
kubectl create secret generic backend-secret \
  --from-literal=SCREEN_JWT_SECRET=$(openssl rand -base64 32) \
  -n game-system
```

### Verify

```bash
kubectl get secret backend-secret -n game-system
kubectl get secret backend-secret -n game-system -o jsonpath='{.data.SCREEN_JWT_SECRET}' | base64 -d
```

---

## Creating `ghcr-pull-secret`

Only needed if GHCR images are private. Provide a GitHub Personal Access Token with the `read:packages` scope.

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=flipgame-hetic \
  --docker-password=<github-pat> \
  --namespace=game-system

# Patch the default ServiceAccount so all pods pick it up automatically
kubectl patch serviceaccount default -n game-system \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
```

---

## How secrets are injected into pods

### Backend — SCREEN_JWT_SECRET

```yaml
# backend/deployment.yaml
env:
  - name: SCREEN_JWT_SECRET
    valueFrom:
      secretKeyRef:
        name: backend-secret
        key: SCREEN_JWT_SECRET
```

The backend pod reads the secret at startup. If the secret does not exist when the pod is scheduled, it stays in `CreateContainerConfigError`.

---

## Grafana — admin password

The Grafana password is passed at runtime via the `GRAFANA_PASSWORD` environment variable:

```bash
GRAFANA_PASSWORD=<password> ./scripts/deploy.sh
```

The script passes it to Helm:
```bash
helm upgrade --install kube-prom ... --set grafana.adminPassword="$GRAFANA_PASSWORD"
```

**This password is also stored by Helm** in a Kubernetes Secret named `kube-prom-grafana` in the `monitoring` namespace. Grafana reads it at startup.

---

## Current security issues

### 1. No dedicated secret management solution

Secrets are created manually with `kubectl create secret`. There is no automatic rotation, no encryption at rest beyond K3s's etcd, and no secret access auditing.

**Potential solutions:**

| Solution | Principle | Complexity |
|----------|-----------|------------|
| **Sealed Secrets** (Bitnami) | Encrypts secrets in git with an asymmetric key | Low |
| **External Secrets Operator** | Syncs from Vault/AWS SSM/etc. | Medium |
| **HashiCorp Vault** | Dedicated secrets manager | High |

**Recommendation: Sealed Secrets** for the current phase. SealedSecret objects can be committed to git; only the cluster can decrypt them.

```bash
# Install Sealed Secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Create a SealedSecret
echo -n 'my-secret-value' | kubeseal --raw --from-file=/dev/stdin \
  --namespace game-system --name backend-secret --scope strict
```

### 2. K3s secrets not encrypted at rest

By default, Kubernetes secrets are stored as base64 in etcd, without volume encryption. K3s stores etcd in SQLite. To enable encryption:

```yaml
# /etc/rancher/k3s/config.yaml
kube-apiserver-arg:
  - encryption-provider-config=/etc/rancher/k3s/encryption.yaml
```

### 3. Grafana password in shell environment variable

`GRAFANA_PASSWORD=... ./scripts/deploy.sh`: the variable may be logged in bash history. Use a `.env` file (not committed) instead:

```bash
# .env (in .gitignore)
GRAFANA_PASSWORD=xxxx

# Usage
source .env && ./scripts/deploy.sh
```

---

## Secret rotation

### Rotating SCREEN_JWT_SECRET

1. Generate a new secret: `openssl rand -base64 32`
2. Update the Kubernetes Secret:
   ```bash
   kubectl create secret generic backend-secret \
     --from-literal=SCREEN_JWT_SECRET=<new-secret> \
     -n game-system \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Restart the backend to reload the environment variable:
   ```bash
   kubectl rollout restart deployment/backend -n game-system
   ```

**Warning:** All JWT tokens issued with the old secret will be invalidated. Screens will need to re-authenticate.

### Rotating the Grafana password

```bash
GRAFANA_PASSWORD=new_password ./scripts/deploy.sh
# Helm updates the Secret, Grafana restarts automatically
```

---

## RBAC for secrets

Currently, no granular RBAC policy is configured. Any `ServiceAccount` in `game-system` can read all Secrets in the namespace.

To restrict access:
```yaml
# Allow only the backend ServiceAccount to read backend-secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backend-secret-reader
  namespace: game-system
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["backend-secret"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-secret-reader
  namespace: game-system
subjects:
  - kind: ServiceAccount
    name: backend  # Dedicated ServiceAccount to create
roleRef:
  kind: Role
  name: backend-secret-reader
  apiGroup: rbac.authorization.k8s.io
```
