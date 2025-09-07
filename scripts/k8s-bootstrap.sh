#!/usr/bin/env bash
set -euo pipefail

# Simple helper to pull kubeconfig, install cert-manager, and apply base manifests.
# Usage: ./scripts/k8s-bootstrap.sh <server-ip> <cloudflare-api-token> <email>

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <server-ip> <cloudflare-api-token> <email>" >&2
  exit 1
fi

SERVER_IP="$1"
CF_TOKEN="$2"
EMAIL="$3"

OUT_KUBECONFIG="kubeconfig"

echo "[+] Fetching kubeconfig from server"
ssh root@"${SERVER_IP}" 'cat /root/.kube/config' > "${OUT_KUBECONFIG}"
sed -i "s/127.0.0.1/${SERVER_IP}/" "${OUT_KUBECONFIG}" || true
export KUBECONFIG=$PWD/${OUT_KUBECONFIG}

kubectl cluster-info || { echo "kubectl cannot reach cluster"; exit 1; }

echo "[+] Installing cert-manager CRDs and controller"
CM_VERSION="v1.15.0"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.crds.yaml
kubectl create namespace cert-manager 2>/dev/null || true
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml

# Wait for cert-manager deployments ready
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s || true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s || true
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=120s || true

echo "[+] Creating Cloudflare API token secret"
# Place secret in cert-manager namespace to match manifest expectation
kubectl -n cert-manager delete secret cloudflare-api-token 2>/dev/null || true
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="${CF_TOKEN}"

echo "[+] Patching ClusterIssuer email placeholders"
# Temporary substitution for email fields in clusterissuer if still default
TMP_FILE=$(mktemp)
sed "s/you@example.com/${EMAIL}/g" k8s/cert-manager/clusterissuer.yaml > "$TMP_FILE"


echo "[+] Applying namespaces and apps"
kubectl apply -f k8s/namespaces/namespaces.yaml
kubectl apply -f k8s/apps/

echo "[+] Applying ClusterIssuer"
kubectl apply -f "$TMP_FILE"
rm "$TMP_FILE"

echo "[+] Applying Ingress"
kubectl apply -f k8s/ingress/ingress.yaml

echo "[+] Done. Verify certificate status with: kubectl describe certificate -n web multi-domain-tls"
