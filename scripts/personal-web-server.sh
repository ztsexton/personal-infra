#!/usr/bin/env bash
set -euo pipefail

# Usage: SSH_USER=root ./scripts/personal-web-server.sh [optional remote command]
# Environment overrides:
#   VPS_IP_OVERRIDE        Manually specify server IP (if remote state not local)
#   AUTO_HOSTKEY_CLEAN=1   Remove existing known_hosts entry before connect
#   SSH_USER               SSH username (default root)

: "${SSH_USER:=root}"

STATE_FILE="terraform/terraform.tfstate"
SERVER_IP=""
VPS_IP_OVERRIDE="178.156.205.252"

if [ -f "$STATE_FILE" ]; then
  SERVER_IP=$(grep -oE '"vps_ip"[^\n]*' "$STATE_FILE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
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