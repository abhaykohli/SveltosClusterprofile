# Sveltos Multi-Cluster Helm Chart Deployment with Templating


> **Deploy the same Helm chart with different configurations across multiple Kubernetes clusters using a single ClusterProfile**

This repository demonstrates how to use **Sveltos** to deploy NGINX with **environment-specific configurations** using Helm chart templating. You'll deploy to staging with 1 replica and production with 3 replicas—all managed by a single `ClusterProfile` resource.


---

##  Overview

This tutorial showcases **Sveltos templating** capabilities by deploying the same NGINX Helm chart with different replica counts and resource allocations to staging and production clusters.

### What Gets Deployed

| Cluster | Replicas | CPU Request | Memory Request | Label |
|---------|----------|-------------|----------------|-------|
| **Staging** | 1 | 100m | 128Mi | `env=staging` |
| **Production** | 3 | 500m | 512Mi | `env=production` |

**Key Point**: One `ClusterProfile`, multiple clusters, different configurations!

---



---

##  Architecture

```
┌─────────────────────────────────────────────────────────────┐
│             Management Cluster                              │
│         (kind-sveltos-management)                           │
│                                                             │
│  ┌────────────────────────────────────────────┐           │
│  │  ClusterProfile: deploy-nginx-templated    │           │
│  │                                             │           │
│  │  Selector: env=staging OR env=production    │           │
│  │                                             │           │
│  │  Template:                                  │           │
│  │    replicas: {{ if prod }}3{{ else }}1{{}} │           │
│  └────────────────────────────────────────────┘           │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                │
│  │ ClusterSummary  │  │ ClusterSummary  │                │
│  │   (staging)     │  │  (production)   │                │
│  └────────┬────────┘  └────────┬────────┘                │
└───────────┼────────────────────┼──────────────────────────┘
            │                     │
            │ Docker Network      │
            │ (sveltos-network)   │
            │                     │
┌───────────▼────────┐  ┌────────▼────────────┐
│  Staging Cluster   │  │ Production Cluster  │
│  (kind-staging)    │  │ (kind-production)   │
│                    │  │                     │
│  ┌──────────────┐ │  │ ┌──────────────┐   │
│  │ NGINX        │ │  │ │ NGINX        │   │
│  │ 1 replica    │ │  │ │ 3 replicas   │   │
│  │ 100m CPU     │ │  │ │ 500m CPU     │   │
│  │ 128Mi RAM    │ │  │ │ 512Mi RAM    │   │
│  └──────────────┘ │  │ └──────────────┘   │
└───────────────────┘  └─────────────────────┘
```

---

##  Prerequisites


### Install Required Tools

```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Install sveltosctl
curl -L https://github.com/projectsveltos/sveltosctl/releases/latest/download/sveltosctl_linux_amd64.tar.gz -o sveltosctl.tar.gz
tar -xzf sveltosctl.tar.gz
sudo mv sveltosctl /usr/local/bin/
```

##  Quick Start

If you just want to see it working quickly:

```bash
# Clone this repository
git clone https://github.com/abhaykohli/SveltosClusterprofile.git
cd SveltosClusterprofile

# Run the automated setup script
chmod +x setup-sveltos-demo.sh
./setup-sveltos-demo.sh

# Wait 5-10 minutes for complete setup

# Verify deployment
kubectl get sveltoscluster -A
kubectl --context kind-staging get deployment -n apps nginx
kubectl --context kind-production get deployment -n apps nginx
```

---


### Phase 1: Setup Management Cluster

#### Create Management Cluster

```bash
# Create management cluster
kind create cluster --name sveltos-management

# Verify cluster is ready
kubectl cluster-info --context kind-sveltos-management
```

#### 1.2 Install cert-manager

Sveltos requires cert-manager for webhook certificates.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s \
  -n cert-manager deployment --all
```

#### Install Sveltos

```bash
# Add Sveltos Helm repository
helm repo add projectsveltos https://projectsveltos.github.io/helm-charts
helm repo update

# Install Sveltos
helm install projectsveltos projectsveltos/projectsveltos \
  -n projectsveltos --create-namespace

# Wait for Sveltos components to be ready
kubectl wait --for=condition=Available --timeout=300s \
  -n projectsveltos deployment --all


### Phase 2: Create Workload Clusters

#### 2.1 Create Staging Cluster

```bash
kind create cluster --name staging
```

####  Create Production Cluster

```bash
kind create cluster --name production
```

#### Verify Clusters

```bash
kind get clusters
```

Expected output:
```
production
staging
sveltos-management
```

---

### Phase 3: Setup Docker Networking required only if on WSL and using KIND skip if not using it !!

This is **CRITICAL** for cluster-to-cluster communication.

####  Create Docker Network

```bash
# Create a custom bridge network
docker network create sveltos-network
```

#### Connect All Clusters

```bash
# Connect management cluster
docker network connect sveltos-network sveltos-management-control-plane

# Connect staging cluster
docker network connect sveltos-network staging-control-plane

# Connect production cluster
docker network connect sveltos-network production-control-plane
```

####  Verify Network Connectivity

```bash
# Check network connections
docker network inspect sveltos-network | grep -A 5 "Containers"
```

You should see all three control-plane containers listed.

---

### Phase 4: Register Workload Clusters

#### Generate Kubeconfigs with Internal IPs

This is the **KEY STEP** for WSL2/Docker environments.

```bash
# Get kubeconfigs with --internal flag
# This provides container-resolvable addresses
kind get kubeconfig --name staging --internal > /tmp/staging-kubeconfig
kind get kubeconfig --name production --internal > /tmp/production-kubeconfig

# Verify the server addresses
echo "Staging server:"
cat /tmp/staging-kubeconfig | grep server:

echo "Production server:"
cat /tmp/production-kubeconfig | grep server:
```

Expected output shows internal addresses:
```
server: https://staging-control-plane:6443
server: https://production-control-plane:6443
```

#### Register Clusters with Sveltos

```bash
# Switch to management cluster
kubectl config use-context kind-sveltos-management

# Register staging cluster
sveltosctl register cluster \
  --namespace=staging \
  --cluster=staging \
  --kubeconfig=/tmp/staging-kubeconfig \
  --labels=env=staging

# Register production cluster
sveltosctl register cluster \
  --namespace=production \
  --cluster=production \
  --kubeconfig=/tmp/production-kubeconfig \
  --labels=env=production
```

####  Wait for Clusters to be READY

```bash
# Watch cluster status (wait 1-2 minutes)
watch kubectl get sveltoscluster -A
```

Expected output:
```
NAMESPACE    NAME         READY   VERSION
staging      staging      true    v1.34.0
production   production   true    v1.34.0
```


---

### Phase 5: Deploy NGINX with Templating

#### Create ClusterProfile

```bash
cat > clusterprofile-nginx-templated.yaml <<'EOF'
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: deploy-nginx-templated
spec:
  # Select clusters with env=staging OR env=production
  clusterSelector:
    matchExpressions:
    - key: env
      operator: In
      values:
      - staging
      - production
  
  # Continuous sync mode
  syncMode: Continuous
  
  helmCharts:
  - repositoryURL: https://charts.bitnami.com/bitnami
    repositoryName: bitnami
    chartName: bitnami/nginx
    chartVersion: 18.2.4
    releaseName: nginx
    releaseNamespace: apps
    helmChartAction: Install
    
    #  TEMPLATING MAGIC - Different values per cluster!
    values: |
      # Replica count based on environment
      replicaCount: {{ if eq .Cluster.metadata.labels.env "production" }}3{{ else }}1{{ end }}
      
      service:
        type: ClusterIP
      
      # Resources based on environment
      resources:
        requests:
          cpu: {{ if eq .Cluster.metadata.labels.env "production" }}500m{{ else }}100m{{ end }}
          memory: {{ if eq .Cluster.metadata.labels.env "production" }}512Mi{{ else }}128Mi{{ end }}
        limits:
          cpu: {{ if eq .Cluster.metadata.labels.env "production" }}1000m{{ else }}200m{{ end }}
          memory: {{ if eq .Cluster.metadata.labels.env "production" }}1Gi{{ else }}256Mi{{ end }}
EOF
```

#### Apply ClusterProfile

```bash
kubectl apply -f clusterprofile-nginx-templated.yaml
```

#### Monitor Deployment

```bash
# Watch ClusterSummaries being created
watch kubectl get clustersummary -A
```

You should see:
```
NAMESPACE    NAME                                  READY
staging      deploy-nginx-templated-staging-...    Provisioned
production   deploy-nginx-templated-production-... Provisioned
```

####  Using sveltosctl for Better Visibility

```bash
# Show deployed addons
sveltosctl show addons

# Verbose output with details
sveltosctl show addons --verbose
```

---

## ✅ Verification

### Verify Staging Deployment (1 Replica)

```bash
# Check deployment
kubectl --context kind-staging get deployment -n apps nginx

# Verify replica count
kubectl --context kind-staging get deployment -n apps nginx \
  -o jsonpath='{.spec.replicas}'
# Expected: 1

# Check pods
kubectl --context kind-staging get pods -n apps

# Check resources
kubectl --context kind-staging get deployment -n apps nginx \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
```

Expected output:
```json
{
  "limits": {
    "cpu": "200m",
    "memory": "256Mi"
  },
  "requests": {
    "cpu": "100m",
    "memory": "128Mi"
  }
}
```

### Verify Production Deployment (3 Replicas)

```bash
# Check deployment
kubectl --context kind-production get deployment -n apps nginx

# Verify replica count
kubectl --context kind-production get deployment -n apps nginx \
  -o jsonpath='{.spec.replicas}'
# Expected: 3

# Check pods
kubectl --context kind-production get pods -n apps

# Check resources
kubectl --context kind-production get deployment -n apps nginx \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
```

Expected output:
```json
{
  "limits": {
    "cpu": "1000m",
    "memory": "1Gi"
  },
  "requests": {
    "cpu": "500m",
    "memory": "512Mi"
  }
}
```

##  Troubleshooting

### Clusters Not Showing READY

**Issue**: `kubectl get sveltoscluster -A` shows empty READY column

**Solution**: 
```bash
# Check kubeconfig secret
kubectl get secret kubeconfig -n staging -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server

# Verify it uses internal address (not 127.0.0.1)
# Should be: https://staging-control-plane:6443

# If using 127.0.0.1, regenerate with --internal flag
kind get kubeconfig --name staging --internal > /tmp/staging-kubeconfig

# Re-register
kubectl delete sveltoscluster staging -n staging
sveltosctl register cluster --namespace=staging --cluster=staging --kubeconfig=/tmp/staging-kubeconfig --labels=env=staging

### Network Connectivity Issues

**Test connectivity from management cluster**:
```bash
# Get staging Pod IP
STAGING_IP=$(kubectl --context kind-staging get pods -n kube-system kube-apiserver-staging-control-plane -o jsonpath='{.status.podIP}')

# Test from management cluster
kubectl run test-conn --rm -it --image=curlimages/curl --restart=Never -- curl -k --max-time 5 https://${STAGING_IP}:6443/version
```

---

### Sync Modes

- `OneTime` - Deploy once, don't sync changes
- `Continuous` - Continuously sync changes
- `ContinuousWithDriftDetection` - Sync and fix configuration drift
- `DryRun` - Preview changes without applying

### Docker Networking (Why --internal Works)

```
Without --internal:
  kubeconfig → server: https://127.0.0.1:xxxxx
  ❌ Not reachable from other containers

With --internal:
  kubeconfig → server: https://staging-control-plane:6443
  ✅ DNS resolves in Docker network
  ✅ Reachable from other containers
```

The `--internal` flag makes Kind return addresses that work for **container-to-container** communication within Docker networks.

---
Scripts/supported files are in repo!

## 📚 Additional Resources

- [Sveltos Documentation](https://projectsveltos.github.io/sveltos/)
- [Sveltos GitHub](https://github.com/projectsveltos)
- [Sveltos Slack Community](https://join.slack.com/t/projectsveltos/shared_invite/)
---


## ⭐ Show Your Support

If this tutorial helped you, please ⭐ star this repository!

---
