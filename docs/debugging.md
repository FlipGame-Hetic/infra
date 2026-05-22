# Debugging guide

## Quick diagnosis — where to start

```bash
# Overview: everything not Running/Completed
kubectl get pods -A | grep -v "Running\|Completed"

# Recent events (errors, warnings)
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Node state
kubectl get nodes -o wide
```

---

## Common scenarios

### Pod in `CrashLoopBackOff`

A pod starts, crashes, Kubernetes waits, restarts, crashes again…

```bash
# 1. See the crash logs
kubectl logs <pod-name> -n game-system --previous

# --previous: logs from the container that just crashed (not the new one)

# 2. Describe the pod to see events and exit code
kubectl describe pod <pod-name> -n game-system
```

Common causes:
- **Exit code 1**: Application error (bad config, missing variable)
- **Exit code 137**: OOM kill (pod killed for exceeding its memory limit)
- **Exit code 143**: Unhandled SIGTERM (liveness probe timeout)

```bash
# Check for an OOM kill
kubectl describe pod <pod-name> -n game-system | grep -A5 "Last State"
# Look for "OOMKilled" in the "Reason" field
```

---

### Pod in `Pending`

The pod is scheduled but won't start.

```bash
kubectl describe pod <pod-name> -n game-system
# Look at the "Events" section at the bottom
```

Common causes:

**Insufficient resources:**
```
0/2 nodes are available: 2 Insufficient cpu.
```
→ The pod's CPU/Memory requests exceed what is available on the nodes.
```bash
# See allocated vs available resources
kubectl describe nodes | grep -A5 "Allocated resources"
```

**PVC in Pending:**
```
pod has unbound immediate PersistentVolumeClaims
```
→ The PVC has not been created yet or is itself in Pending.
```bash
kubectl get pvc -n game-system
kubectl describe pvc backend-sqlite-pvc -n game-system
```

**Missing secret:**
```
secret "backend-secret" not found
```
→ Create the backend-secret (see [secrets.md](secrets.md)).

---

### Pod in `ImagePullBackOff` / `ErrImagePull`

Kubernetes cannot download the Docker image.

```bash
kubectl describe pod <pod-name> -n game-system
# Events section: "Failed to pull image..."
```

Causes:
- Non-existent image tag: `ghcr.io/flipper/backend:prod` does not exist in the registry
- Private registry without credentials: an `imagePullSecret` would be needed
- No network access to the registry from the cluster

```bash
# Test network connectivity from a pod
kubectl run test-curl --rm -it --restart=Never --image=curlimages/curl \
  -- curl -I https://ghcr.io
```

---

### Application not responding via the Gateway

Scenario: `http://<node-ip>/api/health` returns 404 or connection refused.

**Step 1 — Check Traefik**
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50
```

**Step 2 — Check the Gateway and HTTPRoutes**
```bash
kubectl get gateway -n game-system
kubectl describe gateway flipper-gateway -n game-system
# The "Status" section must show "Accepted: True" and "Programmed: True"

kubectl get httproute -n game-system
kubectl describe httproute backend-route -n game-system
# The "Status" section must show "Accepted: True"
```

If the Gateway or an HTTPRoute shows `Accepted: False`:
```bash
# See detailed conditions
kubectl get gateway flipper-gateway -n game-system -o yaml | grep -A20 "conditions:"
```

**Step 3 — Verify the Service responds directly**
```bash
# Port-forward directly to the backend service
kubectl port-forward svc/backend 8080:8080 -n game-system

# In another terminal
curl http://localhost:8080/health
```

If it responds here but not via the Gateway → Traefik routing issue.
If it doesn't respond here either → application issue in the backend.

**Step 4 — Check the Service endpoints**
```bash
# Is the Service pointing to any pods?
kubectl get endpoints backend -n game-system
# Should show pod IPs, not "<none>"
```

If `<none>`: the Service selector does not match any pod. Check pod labels vs the Service selector.

---

### Backend — SQLite volume issue

```bash
# Check that the PVC is Bound
kubectl get pvc backend-sqlite-pvc -n game-system

# Check that the volume is mounted in the pod
kubectl exec -n game-system deployment/backend -- ls /data

# Read backend logs for SQLite errors
kubectl logs -n game-system deployment/backend --tail=50
```

If the PVC is in `Pending`: see the "PVC stuck in Pending" section below.
If `/data` is empty or the `.db` file is missing: the backend should create it on first startup.

---

### HPA not scaling the backend

```bash
# See the HPA state
kubectl describe hpa backend -n game-system
```

Common causes:

**Metrics Server absent:**
```
unable to get metrics for resource cpu: unable to fetch metrics
```
K3s installs the Metrics Server by default since v1.20. Check:
```bash
kubectl get deployment metrics-server -n kube-system
kubectl top pods -n game-system  # should display CPU/Memory
```

**CPU too low to trigger scale:**
The HPA scales up when CPU exceeds 70% of `requests`. If requests are at 100m, you need to exceed 70m to trigger scaling.

---

### PVC stuck in `Pending`

```bash
kubectl describe pvc backend-sqlite-pvc -n game-system
```

Most common cause with `local-path` and `WaitForFirstConsumer`:
The PVC is waiting for a pod to attempt mounting it to know on which node to create the volume. If the backend pod is not scheduled for another reason (resources, taints), the PVC stays Pending.

→ Fix the pod scheduling issue first; the PVC will resolve automatically.

---

### Node `NotReady`

```bash
kubectl describe node <node-name>
# "Conditions" section: look for the cause in the Message field

# K3s logs on the node (via SSH)
sudo journalctl -u k3s -f        # on the server
sudo journalctl -u k3s-agent -f  # on an agent
```

Common causes:
- Disk pressure (`df -h` on the node → disk full?)
- Memory pressure (`free -h`)
- kubelet crashed (restart K3s: `sudo systemctl restart k3s`)

---

## Logs and monitoring

### View logs in real time

```bash
# All pods of a deployment
kubectl logs -f deployment/backend -n game-system

# A specific pod
kubectl logs -f backend-abc123-xyz -n game-system

# Multiple pods in parallel (with stern)
stern -n game-system backend

# Init container logs (if applicable)
kubectl logs <pod-name> -c init-container-name -n game-system
```

### Loki logs via Grafana

1. Open Grafana: `kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring`
2. Menu → Explore
3. Select datasource "Loki"
4. Query: `{namespace="game-system", app="backend"}`

---

## Advanced debugging tools

### Launch an ephemeral debug pod

```bash
# Temporary pod with network tools
kubectl run debug --rm -it --restart=Never \
  --image=nicolaka/netshoot \
  -n game-system \
  -- bash

# From this pod, test connectivity
curl http://backend:8080/health
nslookup backend
```

### Inspect a crashing pod without letting it crash

```bash
# Temporarily override the command to prevent crashing
kubectl debug deployment/backend -n game-system \
  --copy-to=backend-debug \
  --set-image=backend=ghcr.io/flipgame-hetic/backend:main \
  -- sleep 3600
```

### Check the final configuration of a pod

```bash
# See resolved environment variables (with decoded secrets)
kubectl exec -n game-system <pod-name> -- env | sort

# See the pod's filesystem
kubectl exec -n game-system <pod-name> -- ls /app
```

---

## Quick reference commands

```bash
# --- CLUSTER ---
kubectl get nodes -o wide
kubectl top nodes

# --- PODS ---
kubectl get pods -n game-system -o wide
kubectl get pods -A | grep -v Running
kubectl describe pod <pod> -n game-system
kubectl logs <pod> -n game-system --previous
kubectl exec -it <pod> -n game-system -- bash

# --- SERVICES & ENDPOINTS ---
kubectl get svc -n game-system
kubectl get endpoints -n game-system

# --- GATEWAY API ---
kubectl get gatewayclass
kubectl get gateway -n game-system
kubectl get httproute -n game-system

# --- STORAGE ---
kubectl get pvc -A
kubectl get pv

# --- HPA ---
kubectl get hpa -n game-system
kubectl describe hpa backend -n game-system

# --- EVENTS (recent errors) ---
kubectl get events -n game-system --sort-by='.lastTimestamp'

# --- HELM ---
helm list -A
helm status kube-prom -n monitoring
helm status loki -n monitoring
helm status traefik -n kube-system

# --- PORT-FORWARD ---
kubectl port-forward svc/backend 8080:8080 -n game-system
kubectl port-forward svc/front-screen 8081:80 -n game-system
kubectl port-forward svc/back-screen 8082:80 -n game-system
kubectl port-forward svc/dmd-screen 8083:80 -n game-system
kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring
kubectl port-forward svc/kube-prom-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/loki-gateway 3100:80 -n monitoring
```

---

## Systematic diagnostic checklist

When something is not working, follow this order:

1. `kubectl get pods -A | grep -v Running` → pods in error?
2. `kubectl get events -A --sort-by='.lastTimestamp' | tail -20` → recent error messages?
3. `kubectl logs <error-pod> --previous` → crash logs?
4. `kubectl describe <resource>` → conditions and events on the specific resource?
5. `kubectl get endpoints` → do Services point to any pods?
6. Direct test via port-forward → network or application issue?
7. Grafana/Loki logs → patterns over a longer time period?
