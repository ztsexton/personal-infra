#!/usr/bin/env bash
# Where every secret in the cluster comes from, and whether it arrived.
#
#   ./scripts/secrets.sh status
#   ./scripts/secrets.sh sources
#   ./scripts/secrets.sh resync
#
# There are only two ways a secret gets into these clusters, and knowing which
# one you are looking at tells you where to go when it is missing:
#
#   1. The Terraform bootstrap, over SSH, before Argo CD is running.
#      onepassword-token, op-credentials, cloudflare-api-token (fallback only).
#      Missing => look at /var/log/cluster-bootstrap.log on the node.
#
#   2. The 1Password operator, from a OnePasswordItem CR in git.
#      Everything else. Missing => the operator, Connect, or the vault item.
#
# Nothing should ever be created by hand. If something exists in the cluster that
# neither of these explains, it will not survive a rebuild.
#
# The usual failure is the whole of (2) at once: if Connect cannot read its
# credentials, every OnePasswordItem fails together and the operator still
# reports itself as Running.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"

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

# namespace|secret|how it gets there
BOOTSTRAP_SECRETS=(
  "onepassword|onepassword-token|terraform bootstrap"
  "onepassword|op-credentials|terraform bootstrap"
)

cmd_status() {
  preflight

  step "created by the Terraform bootstrap"
  for row in "${BOOTSTRAP_SECRETS[@]}"; do
    IFS='|' read -r ns name how <<<"$row"
    if k -n "$ns" get secret "$name" >/dev/null 2>&1; then
      printf '  \033[0;32m%-14s %-28s ok\033[0m\n' "$ns" "$name"
    else
      printf '  \033[0;31m%-14s %-28s MISSING (%s)\033[0m\n' "$ns" "$name" "$how"
    fi
  done

  echo
  step "synced from 1Password (one row per OnePasswordItem in git)"
  local items
  items=$(k get onepassworditem -A --no-headers 2>/dev/null || true)
  if [ -z "$items" ]; then
    warn "  no OnePasswordItem CRs -- has Argo CD synced yet?"
  else
    while read -r ns name _; do
      [ -n "$ns" ] || continue
      if k -n "$ns" get secret "$name" >/dev/null 2>&1; then
        printf '  \033[0;32m%-14s %-40s ok\033[0m\n' "$ns" "$name"
      else
        printf '  \033[0;31m%-14s %-40s NOT SYNCED\033[0m\n' "$ns" "$name"
      fi
    done <<<"$items"
  fi

  echo
  step "orphans: in the cluster, explained by neither route"
  # These are the dangerous ones. They exist now and will simply be absent after
  # a rebuild, because nothing declares them. Kubernetes and the operators create
  # plenty of their own secrets, so those patterns are excluded rather than
  # listing every legitimate one by name.
  local declared orphans
  declared=$( { k get onepassworditem -A --no-headers 2>/dev/null | awk '{print $1"/"$2}';
                printf '%s\n' "${BOOTSTRAP_SECRETS[@]}" | awk -F'|' '{print $1"/"$2}'; } | sort -u )
  orphans=$(k get secret -A --no-headers 2>/dev/null \
    | awk '$1=="web" || $1=="cert-manager" || $1=="onepassword" {print $1"/"$2}' \
    | grep -vE '/(sh\.helm\.release|default-token)' \
    | grep -vE '/.*-(tls|certs|cert)$' \
    | grep -vE '/(.*-account-key|cert-manager-webhook-ca)$' \
    | grep -vE '/(pgo-root-cacert|.*-pgbackrest|.*-pguser-.*|.*-cluster-cert|.*-replication-cert)$' \
    | grep -vxF "$declared" || true)
  if [ -z "$orphans" ]; then
    green "  none -- everything is declared somewhere"
  else
    echo "$orphans" | sed 's/^/  /' | while read -r l; do printf '\033[1;33m  %s\033[0m\n' "${l# }"; done
    warn "  created by hand. These vanish on rebuild unless declared in git."
  fi

  echo
  step "1Password Connect (everything above in the second group depends on it)"
  local pods
  pods=$(k -n onepassword get pods --no-headers 2>/dev/null || true)
  [ -n "$pods" ] || { warn "  no pods in the onepassword namespace"; return 0; }
  echo "$pods" | awk '{printf "  %-46s %-8s %s\n", $1, $2, $3}'

  # Running is not the same as working: connect-sync reads its credentials once
  # at startup and then retries in a loop, so a bad credentials file looks
  # healthy from the outside.
  local sync_pod
  sync_pod=$(k -n onepassword get pods -o name 2>/dev/null | grep 'connect-[a-z0-9]*-' | grep -v operator | head -1 || true)
  if [ -n "$sync_pod" ]; then
    if k -n onepassword logs "$sync_pod" -c connect-sync --tail=40 2>/dev/null | grep -q 'credentialsDataFromBase64'; then
      echo
      red "  connect-sync cannot read its credentials file."
      red "  The secret must hold BASE64-ENCODED json, not the raw file."
      red "  Fix the value, then restart it:  $0 resync"
    fi
  fi
}

cmd_sources() {
  preflight
  step "which vault item each secret comes from"
  k get onepassworditem -A -o json 2>/dev/null \
    | "${PY:-python3}" -c '
import sys, json
d = json.load(sys.stdin)
for i in sorted(d["items"], key=lambda x: (x["metadata"]["namespace"], x["metadata"]["name"])):
    m, s = i["metadata"], i.get("spec", {})
    t = i.get("type", "Opaque")
    print("  %-14s %-40s %-34s %s" % (m["namespace"], m["name"], s.get("itemPath", "?"), t))
' || warn "  no OnePasswordItem CRs found"
  echo
  echo "  Anything not listed here and not in the bootstrap group was created by"
  echo "  hand and will not survive a rebuild."
}

cmd_resync() {
  preflight
  step "restarting Connect and the operator"
  # Both read their inputs at startup, so a corrected secret or vault value only
  # takes effect after a restart. The operator additionally backs off on repeated
  # failures, so it can sit idle long after the underlying problem is fixed.
  k -n onepassword rollout restart deploy onepassword-connect >/dev/null 2>&1 || true
  k -n onepassword rollout restart deploy onepassword-connect-operator >/dev/null 2>&1 || true
  k -n onepassword rollout status deploy onepassword-connect --timeout=120s 2>&1 | tail -1
  k -n onepassword rollout status deploy onepassword-connect-operator --timeout=120s 2>&1 | tail -1
  echo
  green "restarted. Re-check in a minute with: $0 status"
}

case "${1:-}" in
  status)  cmd_status ;;
  sources) cmd_sources ;;
  resync)  cmd_resync ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  status    which expected secrets exist, and whether Connect is really working
  sources   which 1Password item each secret comes from
  resync    restart Connect and the operator so they re-read their inputs

Cluster comes from KUBECONFIG, default $REPO/kubeconfig-staging.yaml
EOF
    exit 1 ;;
esac
