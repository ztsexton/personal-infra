#!/usr/bin/env bash
# Read and change Scalr workspace settings through the API.
#
# Every mutating command snapshots the workspace to .scalr-backups/ first, builds
# its payload from the live object so no field is silently dropped, and re-reads
# afterwards to show exactly what changed.
#
#   ./scripts/scalr-workspace.sh show
#   ./scripts/scalr-workspace.sh set-working-dir terraform/envs/production
#   ./scripts/scalr-workspace.sh set-trigger-prefixes terraform/envs/production terraform/modules
#   ./scripts/scalr-workspace.sh restore .scalr-backups/ws.<timestamp>.json
#
# Auth: SCALR_TOKEN, else the token terraform login wrote to
#       ~/.terraform.d/credentials.tfrc.json
# Target: SCALR_WORKSPACE_ID (default: the personal-websites production workspace)
set -euo pipefail

SCALR_HOST="${SCALR_HOST:-zsexton.scalr.io}"
WS="${SCALR_WORKSPACE_ID:-ws-v0oqbtbmqk0da80vn}"
API="https://$SCALR_HOST/api/iacp/v3/workspaces/$WS"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="$REPO/.scalr-backups"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

token() {
  if [ -n "${SCALR_TOKEN:-}" ]; then
    printf '%s' "$SCALR_TOKEN"
    return
  fi
  local f="$HOME/.terraform.d/credentials.tfrc.json"
  [ -f "$f" ] || die "no SCALR_TOKEN and no $f; run: terraform login $SCALR_HOST"
  # piped rather than passed as a filename: a snap-packaged jq has a private /tmp
  # and cannot always open paths given on the command line
  local t
  t=$(cat "$f" | jq -r --arg h "$SCALR_HOST" '.credentials[$h].token // empty')
  [ -n "$t" ] || die "no token for $SCALR_HOST in $f; run: terraform login $SCALR_HOST"
  printf '%s' "$t"
}

get_ws() { # -> full workspace JSON on stdout
  curl -sSf -H "Authorization: Bearer $(token)" "$API" \
    || die "GET failed (expired token? run: terraform login $SCALR_HOST)"
}

summarize() { # workspace JSON on stdin
  jq '{
    id: .data.id,
    name:              .data.attributes.name,
    working_directory: .data.attributes["working-directory"],
    execution_mode:    .data.attributes["execution-mode"],
    auto_apply:        .data.attributes["auto-apply"],
    branch:            .data.attributes["vcs-repo"].branch,
    trigger_prefixes:  .data.attributes["vcs-repo"]["trigger-prefixes"],
    trigger_patterns:  .data.attributes["vcs-repo"]["trigger-patterns"],
    dry_runs:          .data.attributes["vcs-repo"]["dry-runs-enabled"]
  }'
}

snapshot() { # -> path of the backup file on stdout
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/ws.$(date +%Y%m%dT%H%M%S).json"
  get_ws >"$f"
  printf '%s' "$f"
}

patch_ws() { # payload on stdin
  local body rc
  body=$(mktemp)
  rc=$(curl -sS -o "$body" -w '%{http_code}' -X PATCH "$API" \
        -H "Authorization: Bearer $(token)" \
        -H "Content-Type: application/vnd.api+json" \
        --data-binary @-)
  if [ "$rc" != "200" ]; then
    red "PATCH returned HTTP $rc"
    cat "$body" >&2
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
}

report_change() { # before-file
  echo
  echo "--- before ---"; cat "$1" | summarize
  echo "--- after ----"; get_ws | summarize
}

cmd_show() { get_ws | summarize; }

cmd_set_working_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] || die "usage: $0 set-working-dir <path>"
  local before; before=$(snapshot)
  warn "backed up to $before"

  jq -n --arg ws "$WS" --arg dir "$dir" \
    '{data:{type:"workspaces", id:$ws, attributes:{"working-directory":$dir}}}' \
    | patch_ws
  report_change "$before"
  green "working directory set to $dir"
}

cmd_set_trigger_prefixes() {
  [ "$#" -ge 1 ] || die "usage: $0 set-trigger-prefixes <prefix> [prefix...]"
  local before; before=$(snapshot)
  warn "backed up to $before"

  # Build the payload from the live vcs-repo object and change only the one
  # field, so oauth-token-id, branch, path and dry-runs-enabled all survive.
  # webhook-url is server-computed and is not sent back.
  local prefixes
  prefixes=$(printf '%s\n' "$@" | jq -R . | jq -s .)

  cat "$before" | jq --arg ws "$WS" --argjson p "$prefixes" \
    '{data:{type:"workspaces", id:$ws, attributes:{"vcs-repo":(
        .data.attributes["vcs-repo"]
        | ."trigger-prefixes" = $p
        | del(."webhook-url")
      )}}}' \
    | patch_ws
  report_change "$before"
  green "trigger prefixes set to: $*"
}

cmd_restore() {
  local f="${1:-}"
  [ -f "$f" ] || die "usage: $0 restore <backup.json>"
  warn "restoring working-directory and vcs-repo from $f"
  cat "$f" | jq --arg ws "$WS" \
    '{data:{type:"workspaces", id:$ws, attributes:{
        "working-directory": .data.attributes["working-directory"],
        "vcs-repo": (.data.attributes["vcs-repo"] | del(."webhook-url"))
      }}}' \
    | patch_ws
  echo; echo "--- restored to ---"; get_ws | summarize
  green "restored"
}

case "${1:-}" in
  show)                 cmd_show ;;
  set-working-dir)      shift; cmd_set_working_dir "$@" ;;
  set-trigger-prefixes) shift; cmd_set_trigger_prefixes "$@" ;;
  restore)              shift; cmd_restore "$@" ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  show                             print the settings that matter
  set-working-dir <path>           change the Terraform working directory
  set-trigger-prefixes <p> [p...]  replace the VCS trigger prefixes
  restore <backup.json>            put working-dir + vcs-repo back

Workspace: $WS on $SCALR_HOST  (override with SCALR_WORKSPACE_ID / SCALR_HOST)
EOF
    exit 1 ;;
esac
