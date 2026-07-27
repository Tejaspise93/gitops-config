# gitops-config

Configuration repository for the **gitops-app** GitOps pipeline project.

This repo is the GitOps source of truth - it holds the Helm chart and environment-specific values for the application, plus the monitoring stack configuration. No application code lives here. Jenkins writes to it; ArgoCD reads from it.

**Application repo:** [https://github.com/Tejaspise93/gitops-app](https://github.com/Tejaspise93/gitops-app)

**Cluster:** self-managed K3s on AWS, provisioned via Terraform (1 master, N workers) [https://github.com/Tejaspise93/k3s-aws-terraform.git]. Accessed from a local machine with `kubectl` pointed at the cluster or setup a bastion host.

---

## What This Repository Does

This repo is one half of a GitOps pipeline split:

| Repo | Purpose | Who writes to it |
|---|---|---|
| `gitops-app` | Application source code, Dockerfile, Jenkinsfile | Developers |
| `gitops-config` (this repo) | Helm chart, environment values, monitoring config | Jenkins, Github Actions (automated), Engineers (manual) |

ArgoCD watches this repo continuously. When Jenkins updates the image tag in `environments/dev/values.yaml` after a successful build, ArgoCD detects the change and syncs the cluster automatically - no `kubectl` in the pipeline.

---

## Folder Structure

```
gitops-config/
├── bootstrap/
│   ├── argocd-application.yaml        # ArgoCD Application CR (dev) - apply once to bootstrap
│   └── argocd-application-prod.yaml   # ArgoCD Application CR (prod)
├── charts/
│   └── gitops-app/
│       ├── Chart.yaml                 # Chart metadata
│       ├── values.yaml                # Default values
│       └── templates/
│           ├── _helpers.tpl           # Shared Go template helpers
│           ├── deployment.yaml        # Kubernetes Deployment
│           ├── service.yaml           # ClusterIP Service (named "http" port)
│           ├── ingress.yaml           # Ingress (disabled by default)
│           ├── servicemonitor.yaml    # Prometheus scrape target (monitoring namespace)
│           └── prometheusrule.yaml    # Alert rules (down, error rate, latency)
├── environments/
│   ├── dev/
│   │   └── values.yaml                # Dev overrides - image.tag updated by CI pipeline
│   └── prod/
│       └── values.yaml                # Prod overrides - image.tag updated by CI pipeline
├── monitoring/   
│   ├── kube-prometheus-stack-values.yaml  # Prometheus + Grafana + Alertmanager
│   ├── loki-values.yaml                   # Loki (single-binary mode)
│   ├── promtail-values.yaml               # Log shipper
│   └── grafana-loki-datasource.yaml       # Grafana Loki datasource (auto-loaded ConfigMap)
└── docs/
    └── ui-screenshots
```

---

## End-to-End Pipeline Flow

```
Developer pushes code to gitops-app
          |
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
    ArgoCD detects change in gitops-config
    ├── Renders Helm chart with updated values
    ├── Applies manifests to Kubernetes dev namespace
    └── Rolling update → new pod running new image
          │
          v
    Application running at new version, metrics/logs flowing into monitoring stack
    └── Zero-downtime - old pod removed only after new pod passes readiness probe
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
kubectl create namespace prod
kubectl create namespace monitoring

# Verify
kubectl get namespaces
```

### 2. Install ArgoCD

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Verify - all pods should show 1/1 Running
kubectl get pods -n argocd
```

### 3. Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

> Keep this terminal open - closing it stops the port-forward. Browse `https://localhost:8080` (self-signed cert warning is expected).

### 4. Login via ArgoCD CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
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
helm lint charts/gitops-app -f environments/dev/values.yaml

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

### 7. Apply the ArgoCD Application Manifests

```bash
kubectl apply -f bootstrap/argocd-application.yaml -n argocd
kubectl apply -f bootstrap/argocd-application-prod.yaml -n argocd

# Verify both Application CRs were created
kubectl get application -n argocd
```

ArgoCD clones this repo, renders the Helm chart with each environment's values file, and applies the manifests to the matching namespace. Sync status appears in the UI/CLI within a few minutes.

To force an immediate sync rather than waiting for the next poll cycle:

```bash
argocd app sync gitops-app-dev
argocd app sync gitops-app-prod
```

---

## Verifying the Deployment

```bash
# Watch pods
kubectl get pods -n dev -w
kubectl get pods -n prod -w

# Check deployment and service
kubectl get deployment -n dev
kubectl get service -n dev

# Check ArgoCD application health - should show Synced and Healthy
kubectl get application gitops-app-dev -n argocd
kubectl get application gitops-app-prod -n argocd

# Stream pod logs
kubectl logs -n dev -l app.kubernetes.io/name=gitops-app --follow

# Inspect a specific pod if something looks wrong
kubectl describe pod <pod-name> -n dev
```

---

## Testing the Application Endpoints

Ingress is disabled for now - applied later. Use port-forwarding to access the application locally. Use a port other than `9090`/`3000`/`8080` if the monitoring UIs are already tunneled in other terminals (see below), to avoid a bind conflict:

```bash
kubectl port-forward svc/gitops-app -n dev 8081:80
```

With the port-forward running, test the following endpoints:

| Endpoint | Expected Response |
|---|---|
| `http://localhost:8081/health` | `{"status": "ok"}` |
| `http://localhost:8081/hello` | `{"message": "Hello from app version x.x.X-SNAPSHOT"}` |
| `http://localhost:8081/actuator/health` | `{"status":"UP"}` |
| `http://localhost:8081/actuator/prometheus` | Raw Prometheus metrics |

---

## Monitoring Setup

Stack: kube-prometheus-stack (Prometheus + Grafana + Alertmanager) + Grafana Loki +
Promtail, all in the `monitoring` namespace. Config files already exist under
`monitoring/` and `charts/gitops-app/templates/` in this repo - this section covers
installing/applying them, not their contents.

### 1. Label worker nodes

`local-path` (k3s's bundled storage provisioner) pins pods to whichever node they first
land on, so pin the monitoring stack to workers before install, keeping the master free
for control-plane load:

```bash
kubectl label node <worker-1> <worker-2> role=monitoring
```

### 2. Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml
```

### 3. Install Loki + Promtail

```bash
helm install loki grafana/loki \
  --namespace monitoring \
  -f monitoring/loki-values.yaml

helm install promtail grafana/promtail \
  --namespace monitoring \
  -f monitoring/promtail-values.yaml

kubectl apply -f monitoring/grafana-loki-datasource.yaml
```

> If you ever change Loki's persistence/storage settings afterward, `helm upgrade` cannot
> apply it - a StatefulSet's `volumeClaimTemplates` can't change in place:
> ```bash
> helm uninstall loki -n monitoring
> kubectl delete pvc -n monitoring -l app.kubernetes.io/name=loki
> helm install loki grafana/loki -n monitoring -f monitoring/loki-values.yaml
> ```

### 4. Commit and push the app-side ServiceMonitor/PrometheusRule

These live in `charts/gitops-app/templates/` and are only applied once ArgoCD syncs
them - writing the file locally does nothing on its own:

```bash
git add charts/gitops-app/templates/servicemonitor.yaml \
        charts/gitops-app/templates/prometheusrule.yaml \
        charts/gitops-app/values.yaml
git commit -m "add ServiceMonitor and PrometheusRule for gitops-app"
git push

argocd app sync gitops-app-dev
```

### 5. Verify the stack

```bash
kubectl get pods -n monitoring
kubectl get servicemonitor -n monitoring
kubectl get prometheusrule -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20
```

### 6. Access the UIs

```bash
# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
# -> http://localhost:9090

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# -> http://localhost:3000  (admin / see monitoring/kube-prometheus-stack-values.yaml)
```

Confirm Prometheus is scraping the app:
```bash
curl -s http://localhost:9090/api/v1/targets | grep -A5 gitops
```

Query metrics directly (use `--data-urlencode`, not an inline query string, if you're
on Windows Git Bash - embedded quotes get mangled otherwise):
```bash
curl -s --get http://localhost:9090/api/v1/query \
  --data-urlencode 'query=jvm_memory_used_bytes{application="gitops-app"}'
```

### 7. Grafana dashboard

Import via **Dashboards → New → Import**, using one of these IDs (matched to Spring Boot
3 / Micrometer):
- **4701** - JVM (Micrometer) - requires `management.metrics.tags.application=gitops-app`
  set in the app for panels to populate
- **19004** - Spring Boot 3.x Statistics
- **22108** - JVM SpringBoot3 dashboard for Prometheus Operator

Build custom panels (error rate, logs) on their own dashboard/folder rather than editing
the auto-provisioned `kube-state-metrics-v2` dashboard, which can lose manual edits on
chart upgrade.