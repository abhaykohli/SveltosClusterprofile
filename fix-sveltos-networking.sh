#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║   SVELTOS SETUP FOR WSL (Fixed Version)                   ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# We assume clusters are already created from the previous script
# staging, production, sveltos-management

echo "🌐 PHASE 1: Install CNI"
echo "======================="

echo "→ Installing CNI in staging..."
kubectl --context kind-staging apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml > /dev/null 2>&1

echo "→ Installing CNI in production..."
kubectl --context kind-production apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml > /dev/null 2>&1

echo "→ Waiting for nodes to be ready..."
kubectl --context kind-staging wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context kind-production wait --for=condition=Ready nodes --all --timeout=180s

echo "✅ CNI installed!"
echo ""

echo "📦 PHASE 2: Install Sveltos (with longer timeout)"
echo "=================================================="

kubectl config use-context kind-sveltos-management

# Check if cert-manager is already installed
if ! kubectl get namespace cert-manager > /dev/null 2>&1; then
    echo "→ Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml > /dev/null 2>&1
    
    echo "→ Waiting for cert-manager pods..."
    sleep 30
    kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=300s
else
    echo "→ cert-manager already installed"
fi

echo "→ Adding Sveltos Helm repo..."
helm repo add projectsveltos https://projectsveltos.github.io/helm-charts 2>/dev/null || true
helm repo update > /dev/null 2>&1

echo "→ Installing Sveltos..."
helm install projectsveltos projectsveltos/projectsveltos -n projectsveltos --create-namespace 2>/dev/null || echo "  (Already installed or updating...)"

echo "→ Waiting for Sveltos pods..."
sleep 30
kubectl wait --for=condition=Available deployment --all -n projectsveltos --timeout=300s

echo "✅ Sveltos ready!"
echo ""

echo "🔌 PHASE 3: Setup Docker Network"
echo "================================="

# Check if network exists
if ! docker network inspect sveltos-network > /dev/null 2>&1; then
    echo "→ Creating sveltos-network..."
    docker network create sveltos-network
else
    echo "→ sveltos-network already exists"
fi

echo "→ Connecting clusters..."
docker network connect sveltos-network sveltos-management-control-plane 2>/dev/null || echo "  (Management already connected)"
docker network connect sveltos-network staging-control-plane 2>/dev/null || echo "  (Staging already connected)"
docker network connect sveltos-network production-control-plane 2>/dev/null || echo "  (Production already connected)"

echo "✅ Network configured!"
echo ""

echo "📝 PHASE 4: Get API Server Pod IPs"
echo "==================================="

echo "→ Getting staging API server Pod IP..."
kubectl config use-context kind-staging
STAGING_POD_IP=$(kubectl get pods -n kube-system kube-apiserver-staging-control-plane -o jsonpath='{.status.podIP}')
echo "  Staging API Server Pod IP: $STAGING_POD_IP"

echo "→ Getting production API server Pod IP..."
kubectl config use-context kind-production
PRODUCTION_POD_IP=$(kubectl get pods -n kube-system kube-apiserver-production-control-plane -o jsonpath='{.status.podIP}')
echo "  Production API Server Pod IP: $PRODUCTION_POD_IP"

echo "✅ Got Pod IPs!"
echo ""

echo "🔑 PHASE 5: Create Kubeconfigs"
echo "=============================="

kind get kubeconfig --name staging > /tmp/staging-kubeconfig-orig
kind get kubeconfig --name production > /tmp/production-kubeconfig-orig

sed "s|server: https://.*:6443|server: https://${STAGING_POD_IP}:6443|g" /tmp/staging-kubeconfig-orig > /tmp/staging-kubeconfig
sed "s|server: https://.*:6443|server: https://${PRODUCTION_POD_IP}:6443|g" /tmp/production-kubeconfig-orig > /tmp/production-kubeconfig

echo "✅ Kubeconfigs created!"
echo ""

echo "✅ PHASE 6: Test Connectivity"
echo "=============================="

kubectl config use-context kind-sveltos-management

echo "→ Testing staging connectivity..."
if kubectl run test-staging --rm -i --image=curlimages/curl --restart=Never -- curl -k --max-time 5 https://${STAGING_POD_IP}:6443/version > /dev/null 2>&1; then
    echo "  ✓ Can reach staging!"
else
    echo "  ✗ Cannot reach staging (this might be OK, will try registration anyway)"
fi

echo "→ Testing production connectivity..."
if kubectl run test-production --rm -i --image=curlimages/curl --restart=Never -- curl -k --max-time 5 https://${PRODUCTION_POD_IP}:6443/version > /dev/null 2>&1; then
    echo "  ✓ Can reach production!"
else
    echo "  ✗ Cannot reach production (this might be OK, will try registration anyway)"
fi

echo ""

echo "🎯 PHASE 7: Register Clusters"
echo "=============================="

# Clean up any existing registrations
kubectl delete sveltoscluster staging -n staging --ignore-not-found
kubectl delete sveltoscluster production -n production --ignore-not-found
kubectl delete namespace staging --ignore-not-found
kubectl delete namespace production --ignore-not-found

sleep 2

echo "→ Registering staging..."
sveltosctl register cluster \
  --namespace=staging \
  --cluster=staging \
  --kubeconfig=/tmp/staging-kubeconfig \
  --labels=env=staging

echo ""
echo "→ Registering production..."
sveltosctl register cluster \
  --namespace=production \
  --cluster=production \
  --kubeconfig=/tmp/production-kubeconfig \
  --labels=env=production

echo ""
echo "✅ Clusters registered!"
echo ""

echo "⏳ PHASE 8: Waiting for READY"
echo "=============================="

echo "→ Waiting for clusters (up to 4 minutes)..."
echo ""

timeout=240
elapsed=0

while [ $elapsed -lt $timeout ]; do
    STAGING_READY=$(kubectl get sveltoscluster staging -n staging -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    PRODUCTION_READY=$(kubectl get sveltoscluster production -n production -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    
    if [ "$STAGING_READY" = "true" ] && [ "$PRODUCTION_READY" = "true" ]; then
        echo ""
        echo "✅ Both clusters are READY!"
        break
    fi
    
    printf "."
    sleep 5
    elapsed=$((elapsed + 5))
    
    # Show status every 30 seconds
    if [ $((elapsed % 30)) -eq 0 ]; then
        echo ""
        echo "  Current status after ${elapsed}s:"
        kubectl get sveltoscluster -A 2>/dev/null || true
        echo ""
    fi
done

echo ""
echo ""

echo "📊 FINAL STATUS"
echo "==============="
echo ""
kubectl get sveltoscluster -A

echo ""
echo "→ Sveltos Agents:"
echo "  Staging:"
kubectl --context kind-staging get pods -n projectsveltos 2>/dev/null || echo "    (Not deployed yet)"
echo "  Production:"
kubectl --context kind-production get pods -n projectsveltos 2>/dev/null || echo "    (Not deployed yet)"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    SETUP COMPLETE!                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "If clusters are not READY yet:"
echo "  1. Wait a bit longer: watch kubectl get sveltoscluster -A"
echo "  2. Check logs: kubectl logs -n projectsveltos -l app=access-manager"
echo ""