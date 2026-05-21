# Docker image management with Kustomize

## Why use Kustomize for images?

In the base manifests (`kubernetes/ressources/`), images are intentionally generic:

```yaml
# kubernetes/ressources/backend/deployment.yaml
containers:
  - name: backend
    image: backend:latest
```

The name `backend:latest` does not exist anywhere in production — it is a placeholder. Kustomize replaces it on the fly based on the active overlay, without touching the source file. This ensures the base remains neutral and reusable across all environments.

---

## How the `images:` field works

```yaml
# kubernetes/overlays/dev/kustomization.yaml
images:
  - name: backend                            # name to match in Deployments
    newName: ghcr.io/flipgame-hetic/backend  # full registry path
    newTag: main                             # image tag
```

Kustomize traverses all manifests included in the overlay and replaces every container whose `image:` matches the `name` field. The replacement is an exact substitution: `backend:latest` → `ghcr.io/flipgame-hetic/backend:main`.

> Kustomize does not use regexps — `name:` must match exactly the image name declared in the Deployment (without the tag).

---

## The four project images

| `name` (base) | Component | Exposed port |
|---|---|---|
| `backend` | Rust / Axum API | 8080 |
| `front-screen` | Front screen (Vite/React) | 80 |
| `back-screen` | Back screen (Vite/React) | 80 |
| `dmd-screen` | DMD screen (Vite/React) | 80 |

---

## Dev vs Prod — what changes

### Dev (`overlays/dev/`)

```yaml
images:
  - name: backend
    newName: ghcr.io/flipgame-hetic/backend
    newTag: main
  - name: front-screen
    newName: ghcr.io/flipgame-hetic/front-screen
    newTag: main
  - name: back-screen
    newName: ghcr.io/flipgame-hetic/back-screen
    newTag: main
  - name: dmd-screen
    newName: ghcr.io/flipgame-hetic/dmd-screen
    newTag: main
```

The `main` tag corresponds to the main branch in GHCR. This tag is **mutable**: it is overwritten on every merge to `main` by CI. `imagePullPolicy: IfNotPresent` is used — to force a re-pull, delete and recreate the pod.

### Prod (`overlays/prod/`)

```yaml
images:
  - name: backend
    newName: ghcr.io/flipgame-hetic/backend
    newTag: prod
  - name: front-screen
    newName: ghcr.io/flipgame-hetic/front-screen
    newTag: prod
  # ...
```

In prod, the `prod` tag is the production branch tag in GHCR. This tag is updated by CI during a release. `imagePullPolicy: IfNotPresent` ensures the prod cluster does not accidentally re-pull.

---

## Step-by-step: changing an image tag

### 1. Identify the target overlay

```
kubernetes/overlays/
├── dev/kustomization.yaml    ← development environment
└── prod/kustomization.yaml   ← production
```

### 2. Edit the tag in the correct overlay

```yaml
# overlays/prod/kustomization.yaml
images:
  - name: backend
    newName: ghcr.io/flipgame-hetic/backend
    newTag: prod           # ← updated here only
```

Do not touch the Deployment in `ressources/backend/deployment.yaml`.

### 3. Verify the rendered output before applying

```bash
# Show the full manifest as Kustomize would produce it
kubectl kustomize kubernetes/overlays/prod | grep "image:"
```

Expected output:
```
image: ghcr.io/flipgame-hetic/backend:prod
```

### 4. Apply

```bash
kubectl apply -k kubernetes/overlays/prod
```

Kubernetes detects the image change on the Deployment and triggers an automatic rolling update.

---

## Step-by-step: adding a new image

Example — adding a `score-board` service.

### 1. Create the Deployment in the base with a placeholder

```yaml
# kubernetes/ressources/score-board/deployment.yaml
containers:
  - name: score-board
    image: score-board:latest   # placeholder — will be replaced by Kustomize
```

### 2. Reference it in the base root

```yaml
# kubernetes/ressources/kustomization.yaml
resources:
  - namespace
  - backend
  - front-screen
  - back-screen
  - dmd-screen
  - score-board     # ← add
```

### 3. Add the `images:` entry in each overlay

```yaml
# overlays/dev/kustomization.yaml
images:
  # ... existing ...
  - name: score-board
    newName: ghcr.io/flipgame-hetic/score-board
    newTag: main
```

```yaml
# overlays/prod/kustomization.yaml
images:
  # ... existing ...
  - name: score-board
    newName: ghcr.io/flipgame-hetic/score-board
    newTag: prod
```

### 4. Verify

```bash
kubectl kustomize kubernetes/overlays/dev | grep "image:"
```

---

## Why not put the full image directly in the Deployment?

| Approach | Downside |
|----------|----------|
| `image: ghcr.io/.../backend:main` in the base | The base becomes coupled to one environment |
| `image: ghcr.io/.../backend:prod` in the base | The tag must be changed in the base on every release — risk of conflict with dev |
| `image: backend:latest` in the base + `images:` in overlays | The base is neutral, each overlay manages its own lifecycle |

The Kustomize `images:` pattern applies separation of concerns to deployment: the **base** describes the structure, **overlays** describe the target.

---

## Registry: GHCR (GitHub Container Registry)

All images are hosted on `ghcr.io/flipgame-hetic/`. Reading public images requires no authentication. For private images, an `imagePullSecret` must be configured in the `game-system` namespace:

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
