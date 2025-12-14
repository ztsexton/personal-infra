#!/usr/bin/env bash
set -euo pipefail

# Script to generate Docker registry credentials for Zot
# This creates the .dockerconfigjson content needed for the imagePullSecret

echo "======================================"
echo "Generate Zot Registry Credentials"
echo "======================================"
echo ""

read -p "Enter Zot registry URL (default: zot.zachsexton.com): " REGISTRY
REGISTRY=${REGISTRY:-zot.zachsexton.com}

read -p "Enter username (default: admin): " USERNAME
USERNAME=${USERNAME:-admin}

read -sp "Enter password: " PASSWORD
echo ""

if [ -z "$PASSWORD" ]; then
    echo "❌ Password cannot be empty"
    exit 1
fi

# Generate base64 auth string
AUTH_STRING=$(echo -n "$USERNAME:$PASSWORD" | base64)

# Create dockerconfigjson
DOCKER_CONFIG=$(cat <<EOF
{
  "auths": {
    "$REGISTRY": {
      "username": "$USERNAME",
      "password": "$PASSWORD",
      "auth": "$AUTH_STRING"
    }
  }
}
EOF
)

echo ""
echo "======================================"
echo "✅ Generated Docker config:"
echo "======================================"
echo "$DOCKER_CONFIG"
echo ""
echo "======================================"
echo "Next Steps:"
echo "======================================"
echo ""
echo "1. Go to 1Password and create a new item:"
echo "   - Vault: Kubernetes"
echo "   - Title: zot-docker-config"
echo "   - Type: Password"
echo ""
echo "2. Add a field named '.dockerconfigjson' (text type) with the JSON above"
echo ""
echo "3. Save the item in 1Password"
echo ""
echo "4. Apply the OnePasswordItem resource:"
echo "   kubectl apply -f k8s/apps/ballroom-competition-web/onepassword-secret.yaml"
echo ""
echo "5. Wait 1-2 minutes for the 1Password Operator to sync"
echo ""
echo "6. Verify the secret was created:"
echo "   kubectl get secret zot-registry-credentials -n web"
echo ""
echo "7. Deploy the app (it will auto-sync via Argo CD when you push to Git)"
echo ""

# Optionally test docker login
echo ""
read -p "Would you like to test docker login locally? (y/N): " TEST_LOGIN
if [[ "$TEST_LOGIN" =~ ^[Yy]$ ]]; then
    echo "$PASSWORD" | docker login "$REGISTRY" -u "$USERNAME" --password-stdin
    echo "✅ Docker login successful!"
fi
