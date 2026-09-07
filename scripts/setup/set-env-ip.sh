#!/usr/bin/env bash
# Write an environment's public IP into the manifests that hardcode it.
#
# MetalLB needs a literal address pool and Traefik needs a literal
# loadBalancerIP, so each environment's IP appears in two files that Argo CD
# syncs. Rebuilding an environment onto a new address means updating both, and
# missing one leaves Traefik's LoadBalancer stuck pending with every ingress down.
#
#   ./scripts/setup/set-env-ip.sh staging            # show what is set now
#   ./scripts/setup/set-env-ip.sh staging 1.2.3.4    # rewrite both files
#
# Commit and push afterwards: Argo CD is what applies them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

ENV="${1:-}"
NEW="${2:-}"
case "$ENV" in
  production|staging) ;;
  *) die "usage: $0 {production|staging} [new-ip]" ;;
esac

TRAEFIK="$REPO/k8s/argocd/$ENV/traefik.yaml"
POOL="$REPO/k8s/networking/metallb/$ENV/addresspool.yaml"
for f in "$TRAEFIK" "$POOL"; do [ -f "$f" ] || die "missing $f"; done

show() {
  echo "$ENV:"
  echo "  traefik loadBalancerIP : $(grep -oP 'loadBalancerIP:\s*\K[0-9.]+' "$TRAEFIK" || echo '(none)')"
  echo "  metallb address pool   : $(grep -oP '^\s*-\s*\K[0-9.]+-[0-9.]+' "$POOL" || echo '(none)')"
}

if [ -z "$NEW" ]; then show; exit 0; fi

[[ "$NEW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "'$NEW' is not an IPv4 address"

echo "before:"; show

sed -i -E "s/loadBalancerIP:[[:space:]]*[0-9.]+/loadBalancerIP: $NEW/" "$TRAEFIK"
sed -i -E "s/^([[:space:]]*-[[:space:]]*)[0-9.]+-[0-9.]+/\1$NEW-$NEW/" "$POOL"

echo
echo "after:"; show

# A stale address left anywhere else would fail the same way, silently.
echo
leftovers=$(grep -rn --include=*.yaml -E '(loadBalancerIP|^\s*-\s*[0-9.]+-[0-9.]+)' "$REPO/k8s" \
  | grep -vE "$NEW" | grep -v "/production/" || true)
if [ -n "$leftovers" ]; then
  warn "other hardcoded addresses still present (check these belong to another environment):"
  echo "$leftovers" | sed 's/^/  /'
fi

echo
green "updated. Commit and push -- Argo CD applies these, Terraform does not."
