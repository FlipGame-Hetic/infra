# Observability — Prometheus, Grafana, Loki

## Observability architecture

```
Pods (backend, front-screen, back-screen, dmd-screen)
  │  stdout/stderr
  ▼
Loki (log collection)  ─────────────────────────┐
                                                 │
Prometheus (metrics collection)                  │
  │  scrape /metrics                             │
  ▼                                              │
Alertmanager (alert routing)                     │
                                                 ▼
                                         Grafana (UI)
                                           - Dashboards
                                           - Log exploration
                                           - Alerting UI
```

## Why this stack?

**Prometheus + Grafana + Loki** is the standard open-source stack for Kubernetes. Alternatives considered:

| Alternative | Rejected for |
|-------------|-------------|
| Datadog | Cost (per-host billing) |
| New Relic | Same reason |
| ELK Stack (Elasticsearch) | Heavy for 2 nodes, Elasticsearch is RAM-hungry |
| Jaeger (tracing) | Overkill for the current phase, no distributed tracing configured |

The `kube-prometheus-stack` (Prometheus community Helm chart) is the de facto choice: it installs Prometheus Operator, ServiceMonitor/PodMonitor CRDs, AlertManager, and Grafana in a single chart.

---

## Prometheus

### Configuration

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
  serviceMonitorSelectorNilUsesHelmValues: false
  serviceMonitorNamespaceSelector: {}
  serviceMonitorSelector: {}
```

**`serviceMonitorSelectorNilUsesHelmValues: false`**: By default, Prometheus only scrapes ServiceMonitors in the same namespace or with certain labels. Setting this flag to `false` and emptying the selectors lets Prometheus discover **all ServiceMonitors in all namespaces**. Essential for monitoring `game-system` from the `monitoring` namespace.

**`serviceMonitorNamespaceSelector: {}`** and **`serviceMonitorSelector: {}`**: Empty selectors = select everything. Prometheus will discover any ServiceMonitor in the cluster.

### Automatically collected metrics

`kube-prometheus-stack` installs default exporters:

| Exporter | Metrics |
|----------|---------|
| `kube-state-metrics` | State of Kubernetes objects (pods, deployments, PVCs…) |
| `node-exporter` | CPU, memory, disk, network on nodes |
| API Server | Kubernetes API metrics |
| CoreDNS | DNS queries, errors |
| Controller Manager | Reconciliations, queues |
| Scheduler | Scheduling latencies |

### Accessing Prometheus

```bash
kubectl port-forward svc/kube-prom-kube-prometheus-prometheus 9090:9090 -n monitoring
```
→ `http://localhost:9090`

Useful PromQL queries:
```promql
# Backend CPU usage (all pods)
rate(container_cpu_usage_seconds_total{namespace="game-system",pod=~"backend-.*"}[5m])

# Screen memory
container_memory_working_set_bytes{namespace="game-system",pod=~"front-screen-.*|back-screen-.*|dmd-screen-.*"}

# Non-Ready pods
kube_pod_status_ready{namespace="game-system",condition="true"} == 0

# HPA current replicas vs desired
kube_horizontalpodautoscaler_status_current_replicas{namespace="game-system"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="game-system"}
```

---

## Grafana

### Configuration

```yaml
# values-prometheus.yaml
grafana:
  adminPassword: ""    # Injected via --set grafana.adminPassword=$GRAFANA_PASSWORD
  persistence:
    enabled: true
    storageClassName: local-path
    size: 2Gi
```

The password is passed at `helm upgrade --install` time by the `deploy.sh` script:
```bash
helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --set grafana.adminPassword="$GRAFANA_PASSWORD"
```

**Why not put the password in values-prometheus.yaml?**
This file is committed to git. Putting a password in it = exposed secret. Always inject secrets at runtime, never in versioned config files.

### Accessing Grafana

```bash
kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring
```
→ `http://localhost:3000`
- Username: `admin`
- Password: value of `$GRAFANA_PASSWORD`

For permanent access (without port-forward), an HTTPRoute would need to be added to the Gateway:
```yaml
# To create: kubernetes/gateway-api/httproute-grafana.yaml
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /grafana
      backendRefs:
        - name: kube-prom-grafana
          namespace: monitoring
          port: 80
```

### Pre-configured datasources

`kube-prometheus-stack` automatically configures Prometheus as a datasource in Grafana. The Loki datasource is configured through `values-prometheus.yaml` (not the Loki chart):

```yaml
# values-prometheus.yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki-gateway.monitoring.svc.cluster.local
      access: proxy
      jsonData:
        httpHeaderName1: "X-Scope-OrgID"
      secureJsonData:
        httpHeaderValue1: "1"    # Loki tenant ID
```

**`loki-gateway`** is the Helm-generated gateway service — do not use `loki:3100` directly, it bypasses authentication.

**`X-Scope-OrgID: 1`** is required because Loki runs with multi-tenancy enabled. Every query must carry this header or Loki returns 401. `"1"` is the default single-tenant ID.

### Pre-configured dashboards

`kube-prometheus-stack` includes dozens of default dashboards:
- Kubernetes / Cluster overview
- Kubernetes / Nodes
- Kubernetes / Namespaces
- Kubernetes / Deployments
- Kubernetes / Pods
- Prometheus / Overview
- Alertmanager / Overview

---

## Loki

### Simplified architecture (SingleBinary)

```yaml
# values-loki.yaml
deploymentMode: SingleBinary

loki:
  limits_config:
    retention_period: 15d       # Logs older than 15 days are deleted
  compactor:
    retention_enabled: true
    delete_request_store: filesystem  # Required in Loki 3.x with filesystem storage
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: local-path
    size: 10Gi

# Distributed components disabled (single-binary handles everything)
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
```

**Why SingleBinary and not distributed mode?**

Loki can deploy each component separately (querier, ingester, distributor, compactor…). In distributed mode, each component can be scaled independently. But for 2 nodes:
- Distributed mode requires at minimum 4–6 pods just for Loki.
- A single pod in SingleBinary is sufficient for the current load.
- Maintenance is exponentially simpler.

**`replication_factor: 1`**: Logs are not replicated (single pod = no replication possible). If the Loki pod restarts, in-flight logs are lost. For high log availability, switch to distributed mode with `replication_factor: 3`.

### How logs reach Loki

Currently, **no collection agent (Promtail, Alloy) is configured**. Loki receives logs via its HTTP API, but without an agent, pod logs are not sent automatically.

To collect pod logs, Promtail (or Grafana Alloy) must be added:

```bash
# Installing Promtail
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set "config.clients[0].url=http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
```

Promtail runs as a DaemonSet (one pod per node), reads container log files, and sends them to Loki.

### LogQL queries (Loki language)

```logql
# All backend logs
{namespace="game-system", app="backend"}

# Error logs
{namespace="game-system"} |= "ERROR"

# Logs with JSON parsing
{namespace="game-system", app="backend"} | json | level="error"

# Error count per minute
sum(rate({namespace="game-system"} |= "ERROR" [1m])) by (pod)
```

### Accessing Loki directly

```bash
# Port-forward the loki-gateway service (not loki directly)
kubectl port-forward svc/loki-gateway 3100:80 -n monitoring

# Query via API (X-Scope-OrgID required)
curl -H "X-Scope-OrgID: 1" \
  "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="game-system"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000"
```

---

## Alertmanager

Alertmanager is deployed by `kube-prometheus-stack`. It handles routing, grouping, and silencing of Prometheus alerts.

**Current configuration:** Alertmanager is active but no alert routes are configured (no Slack, email, PagerDuty…). Default Prometheus alerts (pod CrashLooping, node down, disk full…) are active but notify no one.

To configure Slack for example:
```yaml
# To add in values-prometheus.yaml
alertmanager:
  config:
    global:
      slack_api_url: '<webhook-url>'
    route:
      receiver: slack
      routes:
        - match:
            severity: critical
          receiver: slack
    receivers:
      - name: slack
        slack_configs:
          - channel: '#alerts'
            title: '{{ .GroupLabels.alertname }}'
```

---

## ServiceMonitor — exposing app metrics

For Prometheus to scrape backend metrics, a ServiceMonitor is needed:

```yaml
# To create: kubernetes/ressources/backend/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: backend
  namespace: game-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: backend
  endpoints:
    - port: http    # Must match the port name in the Service
      path: /metrics
      interval: 30s
```

The Rust/Axum backend must expose `/metrics` in Prometheus format. The `metrics` + `metrics-exporter-prometheus` crates handle this.

---

## Port reference

| Service | Port | Access |
|---------|------|--------|
| Prometheus | 9090 | `kubectl port-forward` |
| Grafana | 80 (pod :3000) | `kubectl port-forward` |
| Loki API | 3100 | `kubectl port-forward` |
| Alertmanager | 9093 | `kubectl port-forward` |
