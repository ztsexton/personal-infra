#!/usr/bin/env bash
set -euo pipefail

# Usage: SSH_USER=root ./scripts/personal-web-server.sh [optional remote command]
# Environment overrides:
#   VPS_IP_OVERRIDE        Manually specify server IP (if remote state not local)
#   AUTO_HOSTKEY_CLEAN=1   Remove existing known_hosts entry before connect
#   SSH_USER               SSH username (default root)

: "${SSH_USER:=root}"

STATE_FILE="terraform/envs/staging/terraform.tfstate"
SERVER_IP=""
# Staging was rebuilt onto a new address; there is no stable fallback to hardcode
# here any more. The IP comes from staging's local Terraform state, or set
# VPS_IP_OVERRIDE yourself:
#   VPS_IP_OVERRIDE=$(cd terraform/envs/staging && terraform output -raw ipv4_address)
VPS_IP_OVERRIDE="${VPS_IP_OVERRIDE:-}"
AUTO_HOSTKEY_CLEAN=1

# Ask Terraform directly: the output is `ipv4_address`, and the old grep looked
# for `vps_ip`, an output name that no longer exists.
if [ -f "$STATE_FILE" ] && command -v terraform >/dev/null 2>&1; then
  SERVER_IP=$(terraform -chdir="$(dirname "$STATE_FILE")" output -raw ipv4_address 2>/dev/null || true)
fi

SERVER_IP=${SERVER_IP:-${VPS_IP_OVERRIDE:-}}

if [ -z "$SERVER_IP" ]; then
  echo "[error] Could not determine server IP. Set VPS_IP_OVERRIDE env var." >&2
  exit 1
fi

if [ "${AUTO_HOSTKEY_CLEAN:-}" = "1" ]; then
  ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
fi

KEY_PATH="mykey.ssh"
if [ ! -f "$KEY_PATH" ]; then
  echo "[error] Missing SSH key at $KEY_PATH" >&2
  exit 1
fi
chmod 600 "$KEY_PATH" 2>/dev/null || true

if [ $# -gt 0 ]; then
  ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "${SSH_USER}"@"$SERVER_IP" "$*"
else
  ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "${SSH_USER}"@"$SERVER_IP"
fi