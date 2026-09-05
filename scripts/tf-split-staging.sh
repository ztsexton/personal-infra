#!/usr/bin/env bash
# Remove staging's resources from production's Terraform state.
#
# State-only: `terraform state rm` forgets a resource, it does not destroy it.
# The staging server and DNS records keep running untouched; they are afterwards
# adopted by terraform/envs/staging.
#
# This must happen AFTER the new layout is what Scalr reads for production, and
# BEFORE production is applied. Run too early -- while master still carries the
# old flat root that declares staging -- and the next plan wants to recreate
# every one of these as a duplicate.
#
#   ./scripts/tf-split-staging.sh check     # what is in state now
#   ./scripts/tf-split-staging.sh backup    # pull a copy of the state first
#   ./scripts/tf-split-staging.sh remove    # do it (prompts, backs up first)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROD_DIR="$REPO/terraform/envs/production"
BACKUP_DIR="$REPO/.tfstate-backups"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

STAGING_ADDRESSES=(
  hcloud_server.staging
  cloudflare_record.zachsexton_staging
  cloudflare_record.zachsexton_argocd_staging
  cloudflare_record.zachsexton_petfoodfinder_staging
  cloudflare_record.zachsexton_vigilo_staging
  cloudflare_record.zachsexton_spotifybutler_staging
  cloudflare_record.zachsexton_grafana_staging
  cloudflare_record.zachsexton_syllabus_staging
  cloudflare_record.zachsexton_zot_staging
  cloudflare_record.petfoodfinder_staging
)

state_list() { terraform -chdir="$PROD_DIR" state list; }

cmd_check() {
  local present=0 absent=0 tmp
  tmp=$(mktemp); state_list >"$tmp"

  echo "Staging addresses in production's state:"
  for a in "${STAGING_ADDRESSES[@]}"; do
    if grep -Fxq "$a" "$tmp"; then
      echo "  present  $a"; present=$((present+1))
    else
      warn "  absent   $a"; absent=$((absent+1))
    fi
  done
  echo
  echo "present=$present absent=$absent"

  echo
  echo "Anything else still in state that looks like staging:"
  grep -i staging "$tmp" | grep -vFf <(printf '%s\n' "${STAGING_ADDRESSES[@]}") || echo "  (nothing)"
  rm -f "$tmp"
}

cmd_backup() {
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/production.$(date +%Y%m%dT%H%M%S).tfstate"
  terraform -chdir="$PROD_DIR" state pull >"$f"
  [ -s "$f" ] || die "state pull produced an empty file"
  green "state backed up to $f ($(wc -c <"$f") bytes)"
  printf '%s' "$f"
}

cmd_remove() {
  local tmp; tmp=$(mktemp); state_list >"$tmp"
  local todo=()
  for a in "${STAGING_ADDRESSES[@]}"; do
    grep -Fxq "$a" "$tmp" && todo+=("$a")
  done
  rm -f "$tmp"

  if [ "${#todo[@]}" -eq 0 ]; then
    green "nothing to do: no staging addresses left in production's state"
    return 0
  fi

  echo "About to remove ${#todo[@]} resource(s) from production's state."
  printf '  %s\n' "${todo[@]}"
  echo
  warn "This forgets them. It does NOT destroy the real staging server or DNS."
  read -r -p "Type 'remove' to continue: " reply
  [ "$reply" = "remove" ] || die "aborted"

  cmd_backup >/dev/null
  local f; f=$(ls -t "$BACKUP_DIR"/production.*.tfstate | head -1)
  warn "backup: $f"

  for a in "${todo[@]}"; do
    echo "removing $a"
    terraform -chdir="$PROD_DIR" state rm "$a"
  done

  echo
  green "done. Production's plan should now be empty -- verify with the PR dry run"
  green "before merging (see terraform/README.md)."
}

case "${1:-}" in
  check)  cmd_check ;;
  backup) cmd_backup; echo ;;
  remove) cmd_remove ;;
  *) echo "usage: $0 {check|backup|remove}" >&2; exit 1 ;;
esac
