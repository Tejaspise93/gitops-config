# gitops-config

Configuration repository for the **gitops-app** GitOps pipeline project.

This repo is the GitOps source of truth — it holds the Helm chart and environment-specific values for the application. No application code lives here. Jenkins writes to it; ArgoCD reads from it.

**Application repo:** [https://github.com/Tejaspise93/gitops-app](https://github.com/Tejaspise93/gitops-app)

---

## What This Repository Does

This repo is one half of a GitOps pipeline split:

| Repo | Purpose | Who writes to it |
|---|---|---|
| `gitops-app` | Application source code, Dockerfile, Jenkinsfile | Developers |
| `gitops-config` (this repo) | Helm chart, environment values | Jenkins (automated), Engineers (manual) |

ArgoCD watches this repo continuously. When Jenkins updates the image tag in `environments/dev/values.yaml` after a successful build, ArgoCD detects the change and syncs the cluster automatically — no `kubectl` in the pipeline.

---

## Folder Structure

```
gitops-config/
├── bootstrap/
│   └── argocd-application.yaml       # ArgoCD Application CR — apply once to bootstrap
├── charts/
│   └── gitops-app/
│       ├── Chart.yaml                # Chart metadata
│       ├── values.yaml               # Default values
│       └── templates/
│           ├── _helpers.tpl          # Shared Go template helpers
│           ├── deployment.yaml       # Kubernetes Deployment
│           ├── service.yaml          # ClusterIP Service
│           └── ingress.yaml          # Ingress (disabled by default)
└── environments/
    └── dev/
        └── values.yaml               # Dev overrides — image.tag updated by Jenkins
```
---

## End-to-End Pipeline Flow

```
Developer pushes code to gitops-app
          |
          v
          v
    Jenkins CI (gitops-app repo)
    ├── Maven build & unit tests
    ├── Docker image build
    ├── Push image to Docker Hub
    │   └── Tagged with Git commit SHA (never 'latest')
    └── Update gitops-config
        └── environments/dev/values.yaml → image.tag: <commit-sha>
          │
          v
          v
    ArgoCD detects change in gitops-config
    ├── Renders Helm chart with updated values
    ├── Applies manifests to Kubernetes dev namespace
    └── Rolling update → new pod running new image
          │
          v
          v
    Application running at new version
    └── Zero-downtime — old pod removed only after new pod passes readiness probe
```

---

## Prerequisites

- A running Kubernetes cluster with `kubectl` configured and pointing to the correct context
- [Helm 3](https://helm.sh/docs/intro/install/) installed
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) installed
- A GitHub Personal Access Token (PAT) with `repo` scope if the repo is private

Verify your tools:

```bash
kubectl version --client
helm version
argocd version --client
```

---

## Setup

### 1. Create Namespaces

```bash
kubectl create namespace argocd
kubectl create namespace dev

# Verify
kubectl get namespaces
```

### 2. Install ArgoCD

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Verify — all 7 pods should show 1/1 Running
kubectl get pods -n argocd
```

### 3. Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

> Keep this terminal open — closing it stops the port-forward.

### 4. Login via ArgoCD CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password <YOUR_ADMIN_PASSWORD> \
  --insecure
```

`--insecure` skips TLS verification against the self-signed cert. Do not use this flag against a production ArgoCD instance.

### 5. Add the Private GitHub Repo (skip if repo is public)

```bash
argocd repo add https://github.com/Tejaspise93/gitops-config.git \
  --username Tejaspise93 \
  --password <YOUR_GITHUB_PAT_TOKEN>

# Verify the connection status shows Successful
argocd repo list
```

Your PAT needs `repo` scope. Generate one at: GitHub → Settings → Developer settings → Personal access tokens.

### 6. Validate the Helm Chart

Run from the root of this repo before applying anything to the cluster:

```bash
# Check for syntax and template errors
helm lint charts/gitops-app \
  -f environments/dev/values.yaml

# Render the final Kubernetes YAML locally
helm template gitops-app charts/gitops-app \
  -f environments/dev/values.yaml \
  --namespace dev

# Validate rendered YAML against the live cluster API schema
helm template gitops-app charts/gitops-app \
  -f environments/dev/values.yaml \
  --namespace dev | kubectl apply --dry-run=client -f -
```

All three commands should pass cleanly before proceeding.

### 7. Apply the ArgoCD Application Manifest

```bash
kubectl apply -f bootstrap/argocd-application.yaml -n argocd

# Verify the Application CR was created
kubectl get application -n argocd
```

ArgoCD will clone this repo, render the Helm chart with `environments/dev/values.yaml`, and apply the manifests to the `dev` namespace. Sync status will appear in the UI and CLI within a few minutes.

To force an immediate sync rather than waiting for the next poll cycle:

```bash
argocd app sync gitops-app-dev
```

---

## Verifying the Deployment

```bash
# Watch pods in the dev namespace
kubectl get pods -n dev -w

# Check the deployment and service
kubectl get deployment -n dev
kubectl get service -n dev

# Check ArgoCD application health — should show Synced and Healthy
kubectl get application gitops-app-dev -n argocd

# Stream pod logs
kubectl logs -n dev -l app.kubernetes.io/name=gitops-app --follow

# Inspect a specific pod if something looks wrong
kubectl describe pod <pod-name> -n dev
```

---

## Testing the Application Endpoints

Ingress is disabled by default in this setup. Use port-forwarding to access the application locally:

```bash
kubectl port-forward svc/gitops-app -n dev 9090:80
```

With the port-forward running, test the following endpoints:

| Endpoint | Expected Response |
|---|---|
| `http://localhost:9090/health` | `{"status": "ok"}` |
| `http://localhost:9090/hello` | `{"message": "Hello from app version x.x.X-SNAPSHOT"}` |
| `http://localhost:9090/actuator/health` | `{"status":"UP"}` |
| `http://localhost:9090/actuator/prometheus` | Raw Prometheus metrics |


---
