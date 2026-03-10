#!/usr/bin/env bash
set -euo pipefail

# Script to create Docker registry credentials for Zot on the k8s cluster.
# The 1Password operator can't create kubernetes.io/dockerconfigjson secrets,
# so this secret is managed manually via kubectl.
#
# Usage: SSH_USER=root ./scripts/personal-prod-server.sh "$(cat scripts/setup-zot-registry-credentials.sh)"
#   or run directly on the server.

REGISTRY="${REGISTRY:-zot.zachsexton.com}"
NAMESPACE="${NAMESPACE:-web}"
SECRET_NAME="${SECRET_NAME:-zot-registry-credentials}"

read -p "Enter username (default: admin): " USERNAME
USERNAME=${USERNAME:-admin}

read -sp "Enter password: " PASSWORD
echo ""

if [ -z "$PASSWORD" ]; then
    echo "Password cannot be empty"
    exit 1
fi

kubectl create secret docker-registry "$SECRET_NAME" \
  --docker-server="$REGISTRY" \
  --docker-username="$USERNAME" \
  --docker-password="$PASSWORD" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret $SECRET_NAME created/updated in namespace $NAMESPACE"
echo "Type: $(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.type}')"
