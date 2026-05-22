#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SERVER_IP="${1:-}"
if [[ -z "$SERVER_IP" ]]; then
  echo "Usage: $0 <server-ip> [agent-ip...]"
  exit 1
fi
shift
AGENT_IPS=("$@")

# K3s server (control-plane)
echo "==> Installing K3s server on $SERVER_IP"
ssh "root@$SERVER_IP" bash <<'REMOTE'
cat > /etc/rancher/k3s/config.yaml <<EOF
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - "feature-gates=GatewayAPI=true"
# Traefik is managed via Helm to control its version and enable Gateway API
disable:
  - traefik
EOF

curl -sfL https://get.k3s.io | sh -

# Wait until the node is Ready before proceeding
until kubectl get node | grep -q " Ready"; do
  echo "  waiting for node to be Ready..."
  sleep 5
done
REMOTE

K3S_TOKEN=$(ssh "root@$SERVER_IP" cat /var/lib/rancher/k3s/server/node-token)
echo "==> Node token retrieved"

# K3s agents (workers)
for AGENT_IP in "${AGENT_IPS[@]}"; do
  echo "==> Joining agent $AGENT_IP to cluster"
  ssh "root@$AGENT_IP" bash <<REMOTE
curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_IP}:6443 K3S_TOKEN=${K3S_TOKEN} sh -
REMOTE
done

# Local kubeconfig
echo "==> Fetching kubeconfig"
scp "root@$SERVER_IP:/etc/rancher/k3s/k3s.yaml" /tmp/k3s.yaml
sed -i "s/127\.0\.0\.1/$SERVER_IP/g" /tmp/k3s.yaml
mkdir -p ~/.kube
cp /tmp/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
echo "  kubeconfig saved to ~/.kube/config"

# Gateway API CRDs
echo "==> Installing Gateway API CRDs"
# --server-side is required for large CRD manifests that exceed the kubectl annotation size limit
kubectl apply --server-side=true -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.05/monthly-2026.05-install.yaml

# Traefik (via Helm, with Gateway API provider enabled)
echo "==> Installing Traefik"
helm repo add traefik https://traefik.github.io/charts --force-update
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --values "$REPO_ROOT/kubernetes/helm/ingress/values-traefik.yaml" \
  --wait

# Namespaces
echo "==> Creating namespaces"
kubectl apply -k "$REPO_ROOT/kubernetes/ressources/namespace"

echo ""
echo "Bootstrap complete. Run ./scripts/deploy.sh to deploy the application."
