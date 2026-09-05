#!/usr/bin/env bash
# Inspect and protect Hetzner primary IPs.
#
# A primary IP created implicitly with a server defaults to auto_delete=true, so
# destroying the server takes the address with it. That is how staging's
# 178.156.242.161 was lost -- and it means every IP hardcoded in the k8s manifests
# (MetalLB address pools, Traefik loadBalancerIP) is one `terraform destroy` away
# from being wrong.
#
#   ./scripts/hcloud-primary-ip.sh list
#   ./scripts/hcloud-primary-ip.sh protect <ip-or-id>     # auto_delete = false
#
# Auth: HCLOUD_TOKEN, else the hcloud_token in terraform/terraform.tfvars.
set -euo pipefail

API="https://api.hetzner.cloud/v1"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

token() {
  if [ -n "${HCLOUD_TOKEN:-}" ]; then printf '%s' "$HCLOUD_TOKEN"; return; fi
  local f="$REPO/terraform/terraform.tfvars"
  [ -f "$f" ] || die "no HCLOUD_TOKEN and no $f"
  local t
  t=$(grep -oP '^hcloud_token\s*=\s*"\K[^"]+' "$f" || true)
  [ -n "$t" ] || die "no hcloud_token found; export HCLOUD_TOKEN instead"
  printf '%s' "$t"
}

api() { # method path [data]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -sSf -X "$m" -H "Authorization: Bearer $(token)" \
      -H "Content-Type: application/json" -d "$d" "$API$p"
  else
    curl -sSf -X "$m" -H "Authorization: Bearer $(token)" "$API$p"
  fi
}

cmd_list() {
  api GET /primary_ips | jq -r '
    .primary_ips[]
    | "\(.ip)\tid=\(.id)\ttype=\(.type)\tauto_delete=\(.auto_delete)\tassignee=\(.assignee_id // "UNASSIGNED")\tname=\(.name)"'
  echo
  warn "auto_delete=true means the address disappears when its server is destroyed."
}

resolve_id() { # ip-or-id -> id
  local q="$1"
  case "$q" in
    [0-9]*.[0-9]*|*:*) api GET /primary_ips | jq -r --arg ip "$q" '.primary_ips[] | select(.ip==$ip) | .id' ;;
    *) printf '%s' "$q" ;;
  esac
}

cmd_protect() {
  local q="${1:-}"
  [ -n "$q" ] || die "usage: $0 protect <ip-or-id>"
  local id; id=$(resolve_id "$q")
  [ -n "$id" ] || die "no primary IP matching '$q'"

  local before
  before=$(api GET "/primary_ips/$id" | jq -r '"\(.primary_ip.ip)  auto_delete=\(.primary_ip.auto_delete)"')
  echo "before: $before"

  api PUT "/primary_ips/$id" '{"auto_delete": false}' >/dev/null

  local after
  after=$(api GET "/primary_ips/$id" | jq -r '"\(.primary_ip.ip)  auto_delete=\(.primary_ip.auto_delete)"')
  echo "after:  $after"
  green "protected: destroying its server will no longer release this address"
}

case "${1:-}" in
  list)    cmd_list ;;
  protect) shift; cmd_protect "$@" ;;
  *) echo "usage: $0 {list|protect <ip-or-id>}" >&2; exit 1 ;;
esac
