#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="flipper-local"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-flipper}"

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
  if helm status traefik --namespace kube-system &>/dev/null; then
    warn "Helm release 'traefik' already deployed in kube-system — skipping."
    return
  fi
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

# Secrets
create_secrets() {
  # postgres-secret
  if kubectl get secret postgres-secret -n game-system &>/dev/null; then
    warn "Secret 'postgres-secret' already exists — skipping."
  else
    log "Creating postgres-secret..."
    kubectl create secret generic postgres-secret \
      --namespace game-system \
      --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
  fi

  # GHCR imagePullSecret
  if [[ -z "$GHCR_TOKEN" ]]; then
    warn "GHCR_TOKEN not set — skipping imagePullSecret creation."
    warn "App images (ghcr.io/flipgame-hetic/*) may fail to pull if the registry is private."
    warn "Set GHCR_TOKEN=<your-github-pat> and rerun to fix."
    return
  fi
  if kubectl get secret ghcr-pull-secret -n game-system &>/dev/null; then
    warn "Secret 'ghcr-pull-secret' already exists — skipping."
  else
    log "Creating ghcr-pull-secret..."
    kubectl create secret docker-registry ghcr-pull-secret \
      --namespace game-system \
      --docker-server=ghcr.io \
      --docker-username=flipgame-hetic \
      --docker-password="$GHCR_TOKEN"
    # Patch the default serviceaccount so all pods pick it up automatically
    kubectl patch serviceaccount default -n game-system \
      -p '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
  fi
}

# App workloads
deploy_app() {
  log "Deploying application (overlay: dev)..."
  kubectl apply -k "$REPO_ROOT/kubernetes/overlays/dev"
}

# Health check
wait_for_pods() {
  log "Waiting for pods in game-system to be Ready (timeout: 3m)..."
  local deadline=$(( $(date +%s) + 180 ))
  local all_ready=false

  while [[ $(date +%s) -lt $deadline ]]; do
    local total
    local ready
    total=$(kubectl get pods -n game-system --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl get pods -n game-system --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
      all_ready=true
      break
    fi
    echo -n "."
    sleep 5
  done
  echo ""

  if [[ "$all_ready" == "true" ]]; then
    log "All pods are Ready."
  else
    warn "Some pods are not Ready after 3 minutes. Current state:"
    kubectl get pods -n game-system
    echo ""
    warn "Pods with issues:"
    kubectl get pods -n game-system --no-headers \
      | grep -v "Running" \
      | awk '{print $1}' \
      | while read -r pod; do
          echo ""
          echo -e "${RED}--- $pod ---${NC}"
          kubectl describe pod "$pod" -n game-system \
            | grep -A 10 "Events:" | tail -10
        done
    die "Fix the issues above then rerun ./scripts/local-up.sh"
  fi
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
  create_secrets
  deploy_app
  deploy_observability
  wait_for_pods
  print_summary
}

main "$@"
