#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="flipper-local"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

# Deps check & install
check_deps() {
  local missing=()
  for cmd in docker k3d kubectl helm; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing tools: ${missing[*]}"
    log "Running install-deps.sh to install them..."
    bash "$SCRIPT_DIR/install-deps.sh"

    # Re-check after install
    local still_missing=()
    for cmd in docker k3d kubectl helm; do
      command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
      die "Still missing after install: ${still_missing[*]}\n  Check install-deps.sh output above."
    fi
  fi
}

# Cluster
create_cluster() {
  if k3d cluster list | grep -q "^$CLUSTER_NAME"; then
    warn "Cluster '$CLUSTER_NAME' already exists — skipping creation."
    return
  fi
  log "Creating k3d cluster '$CLUSTER_NAME' (1 server + 1 agent)..."
  k3d cluster create "$CLUSTER_NAME" \
    --agents 1 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --wait
}

# Gateway API CRDs
install_gateway_crds() {
  if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    warn "Gateway API CRDs already installed — skipping."
    return
  fi
  log "Installing Gateway API CRDs..."
  kubectl apply --server-side=true -f \
    https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.05/monthly-2026.05-install.yaml
}

# Traefik
install_traefik() {
  log "Installing Traefik via Helm..."
  helm repo add traefik https://traefik.github.io/charts --force-update 2>/dev/null
  helm upgrade --install traefik traefik/traefik \
    --namespace kube-system \
    --values "$REPO_ROOT/kubernetes/helm/ingress/values-traefik.yaml" \
    --wait \
    --timeout 3m
}

# Namespaces
create_namespaces() {
  log "Creating namespaces..."
  kubectl apply -k "$REPO_ROOT/kubernetes/ressources/namespace"
}

# App workloads
deploy_app() {
  log "Deploying application (overlay: dev)..."
  kubectl apply -k "$REPO_ROOT/kubernetes/overlays/dev"
}

# Observability
deploy_observability() {
  log "Deploying kube-prometheus-stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update 2>/dev/null
  helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --values "$REPO_ROOT/kubernetes/helm/monitoring/values-prometheus.yaml" \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --wait \
    --timeout 5m

  log "Deploying Loki..."
  helm repo add grafana https://grafana.github.io/helm-charts --force-update 2>/dev/null
  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    --values "$REPO_ROOT/kubernetes/helm/monitoring/values-loki.yaml" \
    --wait \
    --timeout 3m
}

# Summary
print_summary() {
  echo ""
  echo -e "${GREEN}Local cluster is up.${NC}"
  echo ""
  echo "  Grafana   →  kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring"
  echo "               http://localhost:3000  (admin / $GRAFANA_PASSWORD)"
  echo ""
  echo "  Teardown  →  k3d cluster delete $CLUSTER_NAME"
}

main() {
  check_deps
  create_cluster
  install_gateway_crds
  install_traefik
  create_namespaces
  deploy_app
  deploy_observability
  print_summary
}

main "$@"
