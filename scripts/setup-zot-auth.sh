#!/usr/bin/env bash
set -euo pipefail

# Script to set up Zot authentication via 1Password
# This script helps you create the 1Password item for Zot htpasswd authentication

echo "======================================"
echo "Zot Authentication Setup"
echo "======================================"
echo ""
echo "This will generate an htpasswd entry for Zot authentication."
echo ""

# Check if htpasswd is available
if ! command -v htpasswd &> /dev/null; then
    echo "❌ htpasswd command not found. Please install apache2-utils:"
    echo "   sudo apt install apache2-utils"
    exit 1
fi

# Get username
read -p "Enter username (default: admin): " USERNAME
USERNAME=${USERNAME:-admin}

# Get password
read -sp "Enter password for $USERNAME: " PASSWORD
echo ""

if [ -z "$PASSWORD" ]; then
    echo "❌ Password cannot be empty"
    exit 1
fi

# Generate htpasswd entry
echo ""
echo "Generating htpasswd entry..."
HTPASSWD_ENTRY=$(htpasswd -nbB "$USERNAME" "$PASSWORD")

echo ""
echo "======================================"
echo "✅ Generated htpasswd entry:"
echo "======================================"
echo "$HTPASSWD_ENTRY"
echo ""

# Ask if they want to add more users
echo "Would you like to add another user? (y/N): "
read -r ADD_MORE
if [[ "$ADD_MORE" =~ ^[Yy]$ ]]; then
    read -p "Enter username: " USERNAME2
    read -sp "Enter password for $USERNAME2: " PASSWORD2
    echo ""
    HTPASSWD_ENTRY2=$(htpasswd -nbB "$USERNAME2" "$PASSWORD2")
    HTPASSWD_ENTRY="$HTPASSWD_ENTRY
$HTPASSWD_ENTRY2"
    echo ""
    echo "======================================"
    echo "✅ Updated htpasswd entries:"
    echo "======================================"
    echo "$HTPASSWD_ENTRY"
    echo ""
fi

echo ""
echo "======================================"
echo "Next Steps:"
echo "======================================"
echo ""
echo "1. Go to 1Password and create a new item:"
echo "   - Vault: Kubernetes"
echo "   - Title: zot-htpasswd"
echo "   - Type: Password"
echo ""
echo "2. Add a field named 'htpasswd' (password type) with this value:"
echo ""
echo "$HTPASSWD_ENTRY"
echo ""
echo "3. Save the item in 1Password"
echo ""
echo "4. Apply the OnePasswordItem resource:"
echo "   kubectl apply -f k8s/apps/zot/onepassword-secret.yaml"
echo ""
echo "5. Wait 1-2 minutes for the 1Password Operator to sync"
echo ""
echo "6. Restart the Zot deployment:"
echo "   kubectl rollout restart deployment/zot -n web"
echo ""
echo "7. Test authentication:"
echo "   curl -u $USERNAME:YOUR_PASSWORD https://zot.zachsexton.com/v2/"
echo ""

# Optionally save to file
echo "Would you like to save this to a file? (y/N): "
read -r SAVE_FILE
if [[ "$SAVE_FILE" =~ ^[Yy]$ ]]; then
    echo "$HTPASSWD_ENTRY" > /tmp/zot-htpasswd
    echo "✅ Saved to /tmp/zot-htpasswd"
fi
