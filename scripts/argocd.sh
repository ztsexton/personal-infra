#!/usr/bin/env bash
# Argo CD's own health, and reloading it when its config is not actually in force.
#
#   ./scripts/argocd.sh status
#   ./scripts/argocd.sh reload
#
# Several Argo CD settings live in the argocd-cmd-params-cm ConfigMap and reach
# argocd-server as environment variables declared `optional: true`. If a key is
# absent when the pod is created, the variable is simply never set -- and adding
# the key later changes nothing, because env vars are resolved once at pod
# creation. The setting then sits in git, in the ConfigMap, and not in effect,
# with no error anywhere.
#
# Production ran that way from 2026-03-10: server.insecure: true in the
# ConfigMap, ARGOCD_SERVER_INSECURE absent from the running container, so
# argocd-server served TLS to a Traefik speaking plain HTTP and the ingress
# returned 500 -- while every Argo controller synced normally, which is why it
# went unnoticed for six months.
#
# Comparing timestamps does NOT detect this: the ConfigMap object can predate
# the pod while the key inside it does not. The only reliable check is whether
# the variable is actually set in the running container, which is what `status`
# does.
#
# Clusters built by the current bootstrap pass --insecure as a container
# argument instead, so it cannot drift. This is for production, whose Argo CD
# was installed with kubectl and is not managed by that bootstrap.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" -n argocd "$@"; }

preflight() {
  [ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH"
  k get ns >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECONFIG_PATH"
}

server_pod() { k get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

# Every params key the deployment expects, and whether it reached the container.
# `|| true` throughout: a missing variable is the finding, not an error.
params_in_force() {
  local pod="$1"
  k get deploy argocd-server -o json 2>/dev/null | "${PY:-python3}" -c '
import json, sys
d = json.load(sys.stdin)
for e in d["spec"]["template"]["spec"]["containers"][0].get("env", []):
    ref = (e.get("valueFrom") or {}).get("configMapKeyRef") or {}
    if ref.get("name") == "argocd-cmd-params-cm":
        print("%s %s" % (e["name"], ref.get("key")))'
}

cmd_status() {
  preflight
  step "pods"
  k get pods --no-headers 2>/dev/null | awk '{printf "  %-50s %-8s %s\n", $1, $2, $3}'

  local pod; pod=$(server_pod)
  [ -n "$pod" ] || { warn "no argocd-server pod"; return 0; }

  echo
  step "ConfigMap settings, and whether the running pod actually has them"
  local envdump drift=0 unset_count=0
  envdump=$(k exec "$pod" -- printenv 2>/dev/null || true)
  while read -r var key; do
    [ -n "$var" ] || continue
    local cmval running
    cmval=$(k get cm argocd-cmd-params-cm -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null || true)
    running=$(printf '%s\n' "$envdump" | grep "^$var=" | cut -d= -f2- || true)
    if [ -z "$cmval" ]; then
      # The chart wires up dozens of optional params. Listing every one nobody
      # has set buries the one or two that matter, so they are counted instead.
      unset_count=$((unset_count + 1))
    elif [ "$cmval" = "$running" ]; then
      printf '  \033[0;32m%-32s ConfigMap=%-8s container=%s  in force\033[0m\n' "$key" "$cmval" "$running"
    else
      printf '  \033[0;31m%-32s ConfigMap=%-8s container=%s  NOT IN FORCE\033[0m\n' "$key" "$cmval" "${running:-<absent>}"
      drift=1
    fi
  done < <(params_in_force "$pod")

  [ "$unset_count" -gt 0 ] && printf '  (%d other params are unset in the ConfigMap and so use their defaults)\n' "$unset_count"

  if k get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q -- '--insecure'; then
    echo
    green "  --insecure is also a container argument, so it cannot drift"
  elif [ "$drift" = "1" ]; then
    echo
    red "  the running pod was created before those keys existed."
    red "  they take effect on restart:  $0 reload"
  fi
}

cmd_reload() {
  preflight
  local pod; pod=$(server_pod)
  step "before"
  printf '  %s  started %s\n' "$pod" "$(k get pod "$pod" -o jsonpath='{.status.startTime}' 2>/dev/null)"

  warn "Restarting argocd-server. The UI and API drop for a few seconds."
  warn "Running Applications are NOT affected: syncing is the application"
  warn "controller's job, which is a different deployment and is untouched."
  read -r -p "Type 'reload' to continue: " reply
  [ "$reply" = "reload" ] || die "aborted"

  k rollout restart deploy argocd-server >/dev/null
  k rollout status deploy argocd-server --timeout=180s 2>&1 | tail -1

  echo
  step "after"
  local newpod; newpod=$(server_pod)
  printf '  %s  started %s\n' "$newpod" "$(k get pod "$newpod" -o jsonpath='{.status.startTime}' 2>/dev/null)"
  echo
  cmd_status
}

# Sync operations that will never finish.
#
# Argo CD syncs with PruneLast=true, so deletions happen only after every other
# resource reports healthy. If one of those resources is unhealthy BECAUSE of a
# change waiting in the same sync, the two block each other and the operation
# sits in Running indefinitely -- there is no timeout and no error.
#
# Production hit exactly that: Zot was removed from git and needed pruning, the
# Argo CD ingress was unhealthy (502) and needed the fix that was queued behind
# the prune, and the sync ran for twenty hours. Terminating the operation lets
# auto-sync start a fresh one against the current revision.
cmd_unstick() {
  preflight
  local stuck
  stuck=$(k get applications -o json 2>/dev/null | "${PY:-python3}" -c '
import sys, json, datetime as dt
now = dt.datetime.now(dt.timezone.utc)
for a in json.load(sys.stdin).get("items", []):
    op = (a.get("status") or {}).get("operationState") or {}
    if op.get("phase") != "Running":
        continue
    started = op.get("startedAt")
    age = ""
    if started:
        d = now - dt.datetime.fromisoformat(started.replace("Z", "+00:00"))
        # Under ten minutes it is probably just working.
        if d.total_seconds() < 600:
            continue
        age = "%dh%dm" % (d.total_seconds() // 3600, (d.total_seconds() % 3600) // 60)
    print("%s|%s|%s" % (a["metadata"]["name"], age, (op.get("message") or "")[:70]))')

  if [ -z "$stuck" ]; then
    green "no sync has been running long enough to be considered stuck"
    return 0
  fi

  step "sync operations running for over ten minutes"
  while IFS='|' read -r app age msg; do
    printf '  %-22s running %s
    %s
' "$app" "$age" "$msg"
  done <<<"$stuck"

  echo
  warn "Terminating these lets auto-sync start again from the current revision."
  warn "Nothing is deleted and no manifest is applied by this -- it only ends the"
  warn "stalled attempt."
  read -r -p "Type 'unstick' to continue: " reply
  [ "$reply" = "unstick" ] || die "aborted"

  while IFS='|' read -r app age msg; do
    echo "terminating $app"
    k patch application "$app" --type merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null
  done <<<"$stuck"

  echo
  green "terminated. Argo CD will re-sync within its refresh interval."
}

# Ask Argo CD to try again.
#
# Auto-sync gives up after a handful of failures and reports
# "one or more synchronization tasks completed unsuccessfully (retried 5
# times)". It does not try again on its own, so once the underlying cause is
# fixed -- a corrected image, a secret that now exists -- nothing happens until
# a sync is requested. Pushing an empty commit works too; this avoids polluting
# history to nudge a controller.
cmd_sync() {
  preflight
  local app="${1:-}"
  [ -n "$app" ] || die "usage: $0 sync <application>"
  k get application "$app" >/dev/null 2>&1 || die "no Application named '$app'"

  step "before"
  k get application "$app" -o jsonpath='  sync={.status.sync.status} phase={.status.operationState.phase}{"\n"}' 2>/dev/null

  # Setting .operation is exactly what the UI's Sync button does.
  k patch application "$app" --type merge -p \
    '{"operation":{"initiatedBy":{"username":"argocd.sh"},"sync":{"revision":"HEAD"},"retry":{"limit":2}}}' >/dev/null

  green "sync requested"
  echo
  echo "Watch it with:  kubectl -n argocd get application $app -w"
}

case "${1:-}" in
  status) cmd_status ;;
  sync)   shift; cmd_sync "$@" ;;
  unstick) cmd_unstick ;;
  reload) cmd_reload ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  status   pods, and which ConfigMap settings are actually in force
  reload   restart argocd-server so those settings take effect

Cluster comes from KUBECONFIG, default $REPO/kubeconfig-staging.yaml
EOF
    exit 1 ;;
esac
