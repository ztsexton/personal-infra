#!/usr/bin/env bash
# Certificate status, and unsticking cert-manager when it gets wedged.
#
#   ./scripts/certs.sh status
#   ./scripts/certs.sh unstick [cert-name]
#   ./scripts/certs.sh watch
#
# How the pieces fit, since the names are not obvious:
#
#   Certificate         what you asked for: these hostnames, from this issuer
#     -> CertificateRequest   one attempt at fulfilling it
#     -> Order              the ACME order with Let's Encrypt
#       -> Challenge      one per hostname; DNS-01 writes a TXT record via Cloudflare
#
# A Certificate only becomes Ready once every Challenge under it passes. The
# wildcard cert covers two names (zachsexton.com and *.zachsexton.com), so it has
# two Challenges and is the one that tends to stall.
#
# Challenges get permanently stuck when they were created while something they
# needed was missing -- most often the cloudflare-api-token secret. They hold a
# DNS record id with no zone and retry forever against state that no longer
# exists. Deleting the Order makes cert-manager build a fresh one; that is all
# `unstick` does.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"
NS="${CERT_NAMESPACE:-web}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

preflight() {
  [ -f "$KUBECONFIG_PATH" ] \
    || die "no kubeconfig at $KUBECONFIG_PATH -- run: ./scripts/staging.sh kubeconfig"
  k version --request-timeout=10s >/dev/null 2>&1 \
    || die "cannot reach the cluster with $KUBECONFIG_PATH"
}

cmd_status() {
  preflight

  step "certificates"
  k get certificate -A --no-headers 2>/dev/null \
    | awk '{printf "  %-30s READY=%-6s secret=%s\n", $2, $3, $4}' \
    || echo "  none"

  # The issuer needs this to answer the DNS-01 challenge. Its absence is the
  # single most common reason certificates sit at READY=False forever.
  echo
  step "cloudflare token cert-manager solves DNS-01 with"
  if k -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1; then
    k -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data}' 2>/dev/null \
      | "${PY:-python3}" -c 'import sys,json; print("  present, keys:", list(json.load(sys.stdin).keys()))'
  else
    warn "  MISSING -- nothing will ever be issued until this exists"
  fi

  echo
  step "outstanding challenges (empty is what you want)"
  local ch
  ch=$(k -n "$NS" get challenge --no-headers 2>/dev/null || true)
  if [ -z "$ch" ]; then
    green "  none outstanding"
  else
    echo "$ch" | awk '{printf "  %-52s state=%-10s host=%s\n", $1, $2, $3}'
    echo
    warn "  a challenge with no state, or one older than a few minutes, is stuck."
    warn "  clear it with: $0 unstick"
  fi
}

cmd_unstick() {
  preflight
  local only="${1:-}"

  step "orders and challenges before"
  k -n "$NS" get order,challenge --no-headers 2>/dev/null | sed 's/^/  /' || echo "  none"

  local orders
  if [ -n "$only" ]; then
    orders=$(k -n "$NS" get order --no-headers 2>/dev/null | awk -v c="$only" '$1 ~ c {print $1}')
  else
    orders=$(k -n "$NS" get order --no-headers 2>/dev/null | awk '{print $1}')
  fi
  [ -n "$orders" ] || { green "nothing to unstick"; return 0; }

  echo
  warn "about to delete these Orders (and the Challenges under them):"
  printf '  %s\n' $orders
  warn "cert-manager rebuilds them immediately; the Certificate itself is untouched."
  read -r -p "Type 'unstick' to continue: " reply
  [ "$reply" = "unstick" ] || die "aborted"

  for o in $orders; do
    echo "deleting order $o"
    k -n "$NS" delete order "$o" >/dev/null
  done
  # The CertificateRequest holds the reference to the dead Order, so it goes too
  # or cert-manager will keep pointing at the old attempt.
  k -n "$NS" delete certificaterequest --all >/dev/null 2>&1 || true

  echo
  green "cleared. Watch it come back with: $0 watch"
}

cmd_watch() {
  preflight
  local i=0
  until [ $i -ge 30 ]; do
    local total ready
    total=$(k get certificate -A --no-headers 2>/dev/null | wc -l)
    ready=$(k get certificate -A --no-headers 2>/dev/null | awk '$3=="True"' | wc -l)
    printf '  %s  ready %s/%s\n' "$(date +%H:%M:%S)" "$ready" "$total"
    [ "$total" -gt 0 ] && [ "$ready" = "$total" ] && { green "all issued"; return 0; }
    i=$((i+1)); sleep 10
  done
  warn "still not all issued. Check for stuck challenges: $0 status"
  return 1
}

case "${1:-}" in
  status)  cmd_status ;;
  unstick) shift; cmd_unstick "$@" ;;
  watch)   cmd_watch ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  status            certificates, the Cloudflare token, and outstanding challenges
  unstick [name]    delete stuck Orders so cert-manager retries cleanly
  watch             poll until every certificate is Ready

Cluster comes from KUBECONFIG, default $REPO/kubeconfig-staging.yaml
Namespace from CERT_NAMESPACE, default "web"
EOF
    exit 1 ;;
esac
