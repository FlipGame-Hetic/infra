# Infra-Flipper

## Stack:
- [K3s](https://k3s.io/)
- [Terraform](https://www.terraform.io/)
- [Kustomize](https://kustomize.io/)
- [Helm](https://helm.sh/)
- [Grafana](https://grafana.com/)
- [Prometheus](https://prometheus.io/)
- [Loki](https://grafana.com/loki/)


### Why 2 nodes: 
2 nodes strike a balance between resilience and efficiency. We eliminate the single point of failure associated with a single node, without incurring the cost of full high availability, which is only justified for critical, high-traffic services. Our application load comprising a backend and a frontend, does not require a third node, which would remain underutilised.

## Infos: 
**Ingress** is currently in maintenance mode only, so we use the **Gateway API** instead of Ingress in Kubernetes
By default, K3s includes Traefik but with Gateway API support disabled. So we specify this in the K3s configuration at startup:
```yaml
# /etc/rancher/k3s/config.yaml
kube-apiserver-arg:
  - ‘feature-gates=GatewayAPI=true’
```
And we installed Gateway API too:
```bash
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.05/monthly-2026.05-install.yaml
```

K3s natively integrates Traefik, so we have set up a system to ensure that, in production, Traefik replaces the Nginx reverse proxy to avoid conflicts between the two.
Set this via a variable in the .env file, for example 
```
# .env.local
REVERSE_PROXY=nginx

# .env.production  
REVERSE_PROXY=traefik
```

<img width="1303" height="529" alt="Image" src="https://github.com/user-attachments/assets/889456c1-37ae-47c2-95fe-2fbbaf6f4cf4" />



## Launch the infrastructure
### 0. Local setup
```bash
./scripts/local-up.sh
```

### 1. Cluster bootstrap (one-time only)

Install K3s, the Gateway API and Traefik CRDs on the nodes:

```bash
./scripts/bootstrap.sh <server-ip> [agent-ip...]
```

**Example** (2-node cluster):
```bash
./scripts/bootstrap.sh 192.168.1.10 192.168.1.11
```
This script:
- Installs K3s on the control plane with Gateway API enabled
- Joins the worker(s) to the cluster
- Retrieves the kubeconfig from `~/.kube/config`
- Installs the Gateway API CRDs
- Installs Traefik via Helm

### 2. Deploying the application

```bash
GRAFANA_PASSWORD=<your-password> ENV=prod ./scripts/deploy.sh
# or for dev:
GRAFANA_PASSWORD=<your-password> ENV=dev ./scripts/deploy.sh
```

This script deploys:
- Application workloads via the Kustomize overlay (`prod` or `dev`)
- Prometheus + Grafana via Helm
- Loki via Helm

### 3. Accessing Grafana

```bash
kubectl port-forward svc/kube-prom-grafana 3000:80 -n monitoring
```

Then open `http://localhost:3000`.

### Clean up the cluster

```bash
./scripts/cleanup.sh
```
