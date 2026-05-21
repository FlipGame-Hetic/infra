#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
if [[ -z "$GRAFANA_PASSWORD" ]]; then
  echo "Error: GRAFANA_PASSWORD env var is required"
  exit 1
fi

# Auto-detect overlay from the GatewayClass available in the cluster.
# ENV can still be forced explicitly: ENV=dev ./scripts/deploy.sh
if [[ -z "${ENV:-}" ]]; then
  if kubectl get gatewayclass traefik &>/dev/null 2>&1; then
    ENV="prod"
  elif kubectl get gatewayclass nginx &>/dev/null 2>&1; then
    ENV="dev"
  else
    echo "Error: could not detect GatewayClass (traefik/nginx). Set ENV=dev|prod explicitly."
    exit 1
  fi
  echo "==> Auto-detected ENV=$ENV from GatewayClass"
fi

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Error: ENV must be 'dev' or 'prod' (got: $ENV)"
  exit 1
fi

# Application workloads, apply the overlay, not the raw base
# The overlay includes Gateway API routes + tagged images + env patches
echo "==> Deploying application workloads (overlay: $ENV)"
kubectl apply -k "$REPO_ROOT/kubernetes/overlays/$ENV"

# Observability kube-prometheus-stack (Prometheus + Grafana)
echo "==> Deploying kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values "$REPO_ROOT/kubernetes/helm/monitoring/values-prometheus.yaml" \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --wait

# Observability Loki
echo "==> Deploying Loki"
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values "$REPO_ROOT/kubernetes/helm/monitoring/values-loki.yaml" \
  --wait

echo ""
echo "Deployment complete."
echo "Access Grafana: kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring"
