#!/usr/bin/env bash
# Break StatefulSet rollouts that can never finish on their own.
#
#   ./scripts/unstick-rollout.sh status
#   ./scripts/unstick-rollout.sh fix
#
# A StatefulSet RollingUpdate replaces a pod only once the existing one is
# Ready. If that pod is Pending -- most often because it requests more than the
# node has -- it will never be Ready, so the update that would FIX the requests
# is itself blocked by the pod the old requests produced. The rollout sits there
# indefinitely with updateRevision != currentRevision and nothing in the events
# saying the two facts are related.
#
# Deleting the stuck pod is the whole fix: the controller recreates it from the
# updated template. Nothing is lost -- a Pending pod has no running container,
# and StatefulSet PVCs are not deleted with the pod.
#
# `status` only reports. `fix` asks first, and touches only pods that are both
# not-Running and belong to a StatefulSet whose template has already moved on.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)/.."
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

preflight() {
  [ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH"
  k version --request-timeout=10s >/dev/null 2>&1 || die "cannot reach the cluster with $KUBECONFIG_PATH"
}

# ns|sts|pod|reason -- one line per pod worth deleting
stuck() {
  k get sts -A -o json 2>/dev/null | "${PY:-python3}" -c '
import json, subprocess, sys, os
kc = os.environ["KC"]
def kget(*a):
    return json.loads(subprocess.run(["kubectl", "--kubeconfig", kc, *a, "-o", "json"],
                                     capture_output=True, text=True).stdout or "{}")
for s in json.load(sys.stdin).get("items", []):
    st, m = s.get("status", {}), s["metadata"]
    cur, upd = st.get("currentRevision"), st.get("updateRevision")
    if not cur or not upd or cur == upd:
        continue   # not mid-update; nothing to unstick
    ns = m["namespace"]
    sel = ",".join("%s=%s" % kv for kv in s["spec"]["selector"]["matchLabels"].items())
    for p in kget("-n", ns, "get", "pods", "-l", sel).get("items", []):
        phase = p.get("status", {}).get("phase")
        if phase == "Running":
            continue
        # Only pods still on the OLD revision: a new one that is merely slow to
        # start is the rollout working, not stuck.
        if p["metadata"].get("labels", {}).get("controller-revision-hash") == upd:
            continue
        conds = [c for c in (p.get("status", {}).get("conditions") or [])
                 if c.get("type") == "PodScheduled" and c.get("status") != "True"]
        why = conds[0].get("message", phase) if conds else phase
        print("%s|%s|%s|%s" % (ns, m["name"], p["metadata"]["name"], why[:88]))
'
}

cmd_status() {
  preflight
  step "statefulsets mid-update with a pod that cannot become ready"
  local rows; rows=$(KC="$KUBECONFIG_PATH" stuck)
  if [ -z "$rows" ]; then
    green "  none -- no rollout is deadlocked"
    return 0
  fi
  while IFS='|' read -r ns sts pod why; do
    printf '  %-10s %-30s %s\n' "$ns" "$sts" "$pod"
    printf '             %s\n' "$why"
  done <<<"$rows"
  echo
  warn "  the update that would fix these is blocked by the pod they produced."
  warn "  clear it with: $0 fix"
}

cmd_fix() {
  preflight
  local rows; rows=$(KC="$KUBECONFIG_PATH" stuck)
  [ -n "$rows" ] || { green "nothing to unstick"; return 0; }

  step "about to delete these pods"
  while IFS='|' read -r ns sts pod why; do
    printf '  %-10s %s   (from %s)\n' "$ns" "$pod" "$sts"
  done <<<"$rows"
  echo
  warn "Each is recreated immediately from its StatefulSet's updated template."
  warn "No data is lost: these pods are not running, and their PVCs are kept."
  read -r -p "Type 'unstick' to continue: " reply
  [ "$reply" = "unstick" ] || die "aborted"

  while IFS='|' read -r ns sts pod why; do
    echo "deleting $ns/$pod"
    k -n "$ns" delete pod "$pod" --wait=false >/dev/null
  done <<<"$rows"

  echo
  step "waiting for replacements"
  local i=0
  until [ $i -ge 20 ]; do
    local left; left=$(KC="$KUBECONFIG_PATH" stuck | grep -c . || true)
    printf '  %s  still stuck: %s\n' "$(date +%H:%M:%S)" "$left"
    [ "$left" = "0" ] && { green "rollouts are moving again"; return 0; }
    i=$((i+1)); sleep 10
  done
  warn "still stuck -- the new pod may not fit either. Check: $0 status"
  return 1
}

case "${1:-}" in
  status) cmd_status ;;
  fix)    cmd_fix ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  status   statefulsets whose rollout cannot finish, and why
  fix      delete the blocking pods so the updated template takes effect

Cluster comes from KUBECONFIG, default $REPO/kubeconfig-staging.yaml
EOF
    exit 1 ;;
esac
