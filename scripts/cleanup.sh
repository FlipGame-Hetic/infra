#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "WARNING: This will delete all Flipper resources from the cluster."
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# Helm releases
helm uninstall loki         --namespace monitoring 2>/dev/null || true
helm uninstall kube-prom    --namespace monitoring 2>/dev/null || true
helm uninstall traefik      --namespace kube-system 2>/dev/null || true

# Kustomize resources
kubectl delete -k "$REPO_ROOT/kubernetes/ressources" --ignore-not-found

read -r -p "Also remove Gateway API CRDs? [y/N] " confirm_crds
if [[ "$confirm_crds" =~ ^[Yy]$ ]]; then
  kubectl delete -f \
    https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.05/monthly-2026.05-install.yaml \
    --ignore-not-found
fi

echo "Cleanup complete."
echo "To fully uninstall K3s from a node: /usr/local/bin/k3s-uninstall.sh (server) or k3s-agent-uninstall.sh (agent)"
