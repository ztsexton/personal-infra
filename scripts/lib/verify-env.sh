#!/usr/bin/env bash
# Does every configured staging host resolve to this address and serve real TLS?
#
#   scripts/lib/verify-env.sh <ip> [kubeconfig]
#
# Shared by staging.sh and staging-ovh.sh so the list of hostnames exists once.
# Whichever provider is hosting staging, these are the URLs that have to work,
# and a second copy of the list would quietly go stale on one side.
set -euo pipefail

IP="${1:-}"
KC="${2:-}"
[ -n "$IP" ] || { echo "usage: $0 <ip> [kubeconfig]" >&2; exit 2; }

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

# host | namespace | label selector -- the selector is only used to explain a
# failure by naming the pod that is not ready.
HOSTS=(
  "staging.zachsexton.com|web|app=personal-site"
  "petfoodfinder-staging.zachsexton.com|web|app=petfoodfinder"
  "vigilo-staging.zachsexton.com|web|app=vigilo"
  "spotifybutler-staging.zachsexton.com|web|app=spotifybutler"
  "staging.petfoodfinder.app|web|app=ballroom-competition-web"
  "syllabus-staging.zachsexton.com|web|app=ballroom-syllabi"
  "tracker-staging.zachsexton.com|web|app=ballroom-progress-tracker"
  "grafana-staging.zachsexton.com|monitoring|app.kubernetes.io/name=grafana"
  "argocd-staging.zachsexton.com|argocd|app.kubernetes.io/name=argocd-server"
)

# Why is this host not serving? Answered from the cluster, not guessed.
explain() { # namespace selector
  local ns="$1" sel="$2"
  [ -n "$KC" ] && [ -f "$KC" ] || { echo "no kubeconfig"; return; }
  local pod
  pod=$(kubectl --kubeconfig "$KC" -n "$ns" get pods -l "$sel" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$pod" ] || { echo "no pod matching $sel"; return; }

  local phase waiting ev
  phase=$(kubectl --kubeconfig "$KC" -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  waiting=$(kubectl --kubeconfig "$KC" -n "$ns" get pod "$pod" -o json 2>/dev/null \
            | jq -r '[.status.containerStatuses[]? | select(.ready==false) | .state.waiting.reason] | map(select(.)) | first // empty')
  ev=$(kubectl --kubeconfig "$KC" -n "$ns" get events -o json 2>/dev/null \
       | jq -r --arg p "$pod" '[.items[] | select(.involvedObject.name==$p and .type=="Warning")] | last | .message // empty' \
       | tr -d '\n' | head -c 105)
  echo "${phase:-none}${waiting:+/$waiting}${ev:+ | $ev}"
}

fail=0
printf '%-42s %-8s %-6s %s\n' HOST DNS CODE NOTE
for entry in "${HOSTS[@]}"; do
  IFS='|' read -r host ns sel <<<"$entry"

  # `|| true` matters: getent exits 2 when a name does not resolve, and under
  # `set -e` that kills the script mid-list -- so the one thing this tool exists
  # to catch would end the run early and leave every host after it unreported,
  # with the hosts already checked shown as passing.
  got=$(getent hosts "$host" 2>/dev/null | head -1 | awk '{print $1}' || true)
  if [ "$got" = "$IP" ]; then dns=ok; else dns="${got:-none}"; fi

  # No -k: a self-signed cert must count as a failure, since that is exactly
  # what happens when cert-manager cannot solve the DNS01 challenge.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 \
           --resolve "$host:443:$IP" "https://$host/" 2>/dev/null || echo TLS)
  note=""
  case "$code" in
    2*|3*) : ;;
    401|403) note="(auth required -- serving)" ;;
    *) note=$(explain "$ns" "$sel"); fail=1 ;;
  esac
  [ "$dns" = "ok" ] || fail=1

  printf '%-42s %-8s %-6s %s\n' "$host" "$dns" "$code" "$note"
done

echo
if [ "$fail" -eq 0 ]; then
  green "every configured host resolves to $IP and serves over valid TLS"
else
  warn "some hosts are not serving; see NOTE above"
  exit 1
fi
