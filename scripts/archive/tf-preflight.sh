#!/usr/bin/env bash
# Safety gate for the production restructure.
#
# The restructure moves production's resources into modules/environment via the
# `moved` blocks in envs/production/moved.tf. A `moved` block whose `from` address
# is not actually in state is silently a no-op — Terraform then plans to CREATE
# the destination and DESTROY the untracked original. That is the one way this
# change could take production down, and it is entirely detectable before apply.
#
#   ./scripts/archive/tf-preflight.sh workspace   # Scalr workspace settings that matter
#   ./scripts/archive/tf-preflight.sh addresses   # what is really in state right now
#   ./scripts/archive/tf-preflight.sh moved       # do the moved blocks line up with it
#   ./scripts/archive/tf-preflight.sh plan        # hard gate: refuse anything but "no changes"
#
# `plan` is the gate that matters. It exits non-zero unless the plan is empty.
#
# Note: the workspace runs in REMOTE execution mode, and a CLI-driven plan uploads
# only the current directory -- which does not include ../../modules/environment.
# So `plan` here works only with the workspace in local execution mode. The
# equivalent gate for remote execution is the Scalr dry run on a pull request
# (the workspace has dry-runs-enabled), which checks out the whole repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROD_DIR="$ROOT/terraform/envs/production"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

addresses() {
  echo "# Resource addresses currently in production's state:"
  terraform -chdir="$PROD_DIR" state list
}

moved_check() {
  local missing=0 tmp
  tmp=$(mktemp)
  terraform -chdir="$PROD_DIR" state list >"$tmp"

  echo '# Checking every moved block source address against real state.'
  echo

  # Pull the from/to pairs straight out of moved.tf.
  local pairs
  pairs=$(awk '
    /^moved[[:space:]]*\{/ { inblock=1; from=""; to=""; next }
    inblock && /from[[:space:]]*=/ { sub(/.*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); from=$0 }
    inblock && /to[[:space:]]*=/   { sub(/.*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); to=$0 }
    inblock && /^\}/ { print from "\t" to; inblock=0 }
  ' "$PROD_DIR/moved.tf")

  while IFS=$'\t' read -r from to; do
    [ -n "$from" ] || continue
    if grep -Fxq "$from" "$tmp"; then
      green "  ok       $from"
    elif grep -Fxq "$to" "$tmp"; then
      warn  "  already  $from  (state already holds $to)"
    else
      red   "  MISSING  $from  -> neither source nor destination is in state"
      missing=1
    fi
  done <<<"$pairs"

  rm -f "$tmp"
  echo
  if [ "$missing" -ne 0 ]; then
    red "Some moved blocks do not match state; the plan would destroy and recreate"
    red "those resources. Fix moved.tf before planning."
    return 1
  fi
  green "All moved blocks resolve against real state."
}

plan_gate() {
  echo "# Production plan must be empty. Anything else is a failure."
  echo
  set +e
  terraform -chdir="$PROD_DIR" plan -detailed-exitcode -input=false -no-color
  local rc=$?
  set -e

  echo
  case $rc in
    0) green "PASS: production plan is empty. Nothing will be touched." ;;
    2) red   "FAIL: production plan contains changes. Do not apply."
       red   "      The restructure is meant to be a state-only refactor."
       return 1 ;;
    *) red   "FAIL: plan errored (exit $rc)."
       warn "  If this says the working directory was not found, or a module could"
       warn "  not be resolved: that is the remote-execution upload limitation."
       warn "  Gate on a Scalr pull-request dry run instead, or switch the"
       warn "  workspace to local execution mode for the migration."
       return 1 ;;
  esac
}

workspace() {
  local token
  token=$(jq -r '.credentials["zsexton.scalr.io"].token' ~/.terraform.d/credentials.tfrc.json)
  curl -sS -g -H "Authorization: Bearer $token" \
    "https://zsexton.scalr.io/api/iacp/v3/workspaces?filter%5Bname%5D=personal-websites" \
    | jq -r '.data[] | {
        id,
        working_directory: .attributes["working-directory"],
        execution_mode:    .attributes["execution-mode"],
        auto_apply:        .attributes["auto-apply"],
        trigger_prefixes:  .attributes["vcs-repo"]["trigger-prefixes"],
        branch:            .attributes["vcs-repo"].branch
      }'
  echo
  warn "auto_apply must stay false for the migration: it is what guarantees no"
  warn "plan reaches production infrastructure without a human approving it."
}

case "${1:-}" in
  workspace) workspace ;;
  addresses) addresses ;;
  moved)     moved_check ;;
  plan)      plan_gate ;;
  *) echo "usage: $0 {workspace|addresses|moved|plan}" >&2; exit 1 ;;
esac
