#!/usr/bin/env bash
# Make the demo studio login in 1Password actually sign in.
#
#   ./scripts/setup/tracker-demo-login.sh show
#   ./scripts/setup/tracker-demo-login.sh check
#   ./scripts/setup/tracker-demo-login.sh repair
#
# ballroom-progress-tracker bootstraps its demo studio and one admin at app
# startup (src/instrumentation.ts), from BOOTSTRAP_ADMIN_EMAIL and
# BOOTSTRAP_ADMIN_PASSWORD. That bootstrap is CREATE-ONLY: once the studio and
# admin exist it does nothing, by design, so a restart cannot clobber real data.
#
# The consequence nobody wrote down: rotating BOOTSTRAP_ADMIN_PASSWORD in
# 1Password changes nothing in the database. The operator syncs the new value
# into the Secret, the pod restarts with it in its environment, the bootstrap
# sees an admin already there and returns -- and the password in the vault, the
# one a human would reach for, has never been the password that signs in.
#
# On staging as of 2026-09-22 the credential row was written 2026-09-09
# 03:29:38 and its updatedAt has never moved, while the 1Password item is on
# version 3.
#
# `repair` closes that gap in the only place it can be closed: the account row.
# Better Auth stores `<16-byte salt as hex>:<64-byte scrypt key as hex>` and
# derives the key with the salt passed as its hex STRING rather than as bytes,
# which is the detail that makes a hand-rolled hash silently not match. The
# parameters are Better Auth's defaults (N=16384, r=16, p=1, dkLen=64).
#
# Nothing here trusts that reimplementation: `repair` backs the old hash up,
# writes the new one, and then signs in for real against the running app. If
# that fails it puts the old hash back, so a wrong guess costs nothing.
#
# Requires an interactive 1Password session in this shell:  eval $(op signin)
set -euo pipefail

export PATH="$HOME/bin:$PATH"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PY:-$REPO/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

ENV_NAME="${TRACKER_ENV:-staging-ovh}"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-$ENV_NAME.yaml}"
VAULT="${OP_VAULT:-Kubernetes}"
ITEM="${OP_ITEM:-ballroom-progress-tracker-auth}"
FIELD="BOOTSTRAP_ADMIN_PASSWORD"
APP_URL="${TRACKER_URL:-https://tracker-staging.zachsexton.com}"
NAMESPACE=web
DBNAME=ballroom_progress
BACKUP_DIR="${BACKUP_DIR:-$REPO/.argocd-backups}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" --request-timeout=20s "$@"; }

need_session() {
  command -v op >/dev/null || die "the 1Password CLI is not on PATH"
  op whoami >/dev/null 2>&1 || die "no active 1Password session in this shell -- run: eval \$(op signin)"
}

need_cluster() {
  [ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH"
  timeout 20 kubectl --kubeconfig "$KUBECONFIG_PATH" get ns --request-timeout=15s >/dev/null 2>&1 \
    || die "cannot reach the cluster with $KUBECONFIG_PATH"
}

# The Postgres primary. Found by label rather than hardcoded: the instance pod
# name carries a generated suffix that changes whenever PGO rebuilds it.
db_pod() {
  k -n "$NAMESPACE" get pods \
    -l postgres-operator.crunchydata.com/cluster=ballroom-db,postgres-operator.crunchydata.com/role=master \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || true
}

# SQL on stdin, so no value ever reaches the pod's argument list.
psql_stdin() { # sql on stdin
  local pod; pod=$(db_pod)
  [ -n "$pod" ] || die "no Postgres primary pod found in namespace $NAMESPACE"
  k -n "$NAMESPACE" exec -i "$pod" -c database -- psql -U postgres -d "$DBNAME" -A -t -f - 2>/dev/null
}

admin_email() {
  k -n "$NAMESPACE" get deploy ballroom-progress-tracker \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BOOTSTRAP_ADMIN_EMAIL")].value}' 2>/dev/null || true
}

op_password() {
  op item get "$ITEM" --vault "$VAULT" --format json --reveal 2>/dev/null | ITEM_FIELD="$FIELD" "$PY" -c '
import json, os, sys
want = os.environ["ITEM_FIELD"]
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
for f in d.get("fields", []):
    if (f.get("label") or f.get("id")) == want:
        sys.stdout.write(f.get("value") or "")
        break' || true
}

# Better Auth's scrypt, reproduced. The salt goes in as its hex string, not as
# decoded bytes -- that is the part that is easy to get wrong and impossible to
# notice, because a wrong-but-well-formed hash looks exactly like a right one.
scrypt_hash() { # password [salt-hex]
  PW="$1" SALT="${2:-}" "$PY" -c '
import hashlib, os, secrets, unicodedata
pw = unicodedata.normalize("NFKC", os.environ["PW"]).encode()
salt = os.environ.get("SALT") or secrets.token_hex(16)
key = hashlib.scrypt(pw, salt=salt.encode("ascii"), n=16384, r=16, p=1,
                     dklen=64, maxmem=200 * 1024 * 1024)
print("%s:%s" % (salt, key.hex()))'
}

# A real sign-in against the running app. Better Auth answers 200 with a session
# and 401 when the password is wrong, so this distinguishes "the vault value
# works" from "the vault value is merely present".
try_signin() { # password -> 0 ok, 1 rejected, 2 could not tell
  local pw="$1" email code
  email=$(admin_email)
  [ -n "$email" ] || return 2
  code=$(PW="$pw" EMAIL="$email" "$PY" -c '
import json, os, sys, urllib.request, urllib.error
body = json.dumps({"email": os.environ["EMAIL"], "password": os.environ["PW"]}).encode()
req = urllib.request.Request(
    os.environ["URL"] + "/api/auth/sign-in/email", data=body, method="POST",
    headers={"Content-Type": "application/json", "Origin": os.environ["URL"]})
try:
    with urllib.request.urlopen(req, timeout=25) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)' URL="$APP_URL" 2>/dev/null || echo 0)
  case "$code" in
    200|201) return 0 ;;
    401|403|400) return 1 ;;
    *) return 2 ;;
  esac
}

cmd_show() {
  need_session
  need_cluster
  step "1Password"
  local pw; pw=$(op_password)
  if [ -n "$pw" ]; then
    printf '  %-28s %s -> %d chars\n' "$ITEM" "$FIELD" "${#pw}"
  else
    red "  $ITEM / $FIELD is absent or unreadable"
  fi

  echo
  step "the app"
  printf '  url:   %s\n' "$APP_URL"
  printf '  admin: %s\n' "$(admin_email)"

  echo
  step "the credential row in $DBNAME"
  printf 'SELECT "createdAt", "updatedAt" FROM account WHERE "providerId"=%s;\n' "'credential'" \
    | psql_stdin | while IFS='|' read -r created updated; do
        [ -n "$created" ] || continue
        printf '  created: %s\n  updated: %s\n' "$created" "$updated"
        if [ "$created" = "$updated" ]; then
          warn "  never updated since the first bootstrap -- if the vault value has"
          warn "  changed since, it has never been the password that signs in"
        fi
      done
  echo
  echo "Values are not printed. Whether the stored login actually works:  $0 check"
}

cmd_check() {
  need_session
  need_cluster
  local pw; pw=$(op_password)
  [ -n "$pw" ] || die "$ITEM / $FIELD is absent or unreadable in vault '$VAULT'"

  step "signing in to $APP_URL as $(admin_email)"
  local rc=0
  try_signin "$pw" || rc=$?
  case "$rc" in
    0) green "  the password in 1Password signs in. Nothing to fix." ; return 0 ;;
    1) red   "  rejected: the password in 1Password is NOT the one in the database."
       red   "  fix it with:  $0 repair"
       return 1 ;;
    *) warn  "  could not reach the sign-in endpoint; is $APP_URL serving?"
       return 2 ;;
  esac
}

cmd_repair() {
  need_session
  need_cluster

  local pw; pw=$(op_password)
  [ -n "$pw" ] || die "$ITEM / $FIELD is absent or unreadable in vault '$VAULT'"

  local email; email=$(admin_email)
  [ -n "$email" ] || die "the deployment declares no BOOTSTRAP_ADMIN_EMAIL"

  step "checking whether anything needs repairing"
  local rc=0
  try_signin "$pw" || rc=$?
  if [ "$rc" = "0" ]; then green "  the stored password already signs in -- nothing to do"; return 0; fi
  [ "$rc" = "1" ] || die "could not reach $APP_URL to test a sign-in; not touching the database"

  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local backup="$BACKUP_DIR/tracker-credential-$ENV_NAME-$(date -u +%Y%m%dT%H%M%SZ).sql"
  step "backing up the existing hash"
  ( umask 077; printf 'SELECT id || %s || password FROM account WHERE "providerId"=%s;\n' "'|'" "'credential'" \
      | psql_stdin > "$backup" )
  [ -s "$backup" ] || die "could not read the existing credential row; nothing was changed"
  green "  saved to $backup"

  local old_id old_hash
  IFS='|' read -r old_id old_hash < "$backup"
  [ -n "$old_id" ] || die "could not parse the credential row from the backup"

  warn "This rewrites the demo admin's password hash to the value in 1Password."
  warn "Existing sessions are unaffected; the old password stops working."
  read -r -p "Type 'repair' to continue: " reply
  [ "$reply" = "repair" ] || die "aborted"

  local newhash; newhash=$(scrypt_hash "$pw")
  step "writing the new hash"
  printf 'UPDATE account SET password=%s, "updatedAt"=now() WHERE id=%s;\n' "'$newhash'" "'$old_id'" \
    | psql_stdin >/dev/null

  # The reimplementation is only believable if a real sign-in succeeds.
  step "verifying by signing in"
  rc=0
  try_signin "$pw" || rc=$?
  if [ "$rc" = "0" ]; then
    green "  the password in 1Password now signs in"
    echo
    echo "  user: $email"
    echo "  url:  $APP_URL"
    return 0
  fi

  red "  still rejected -- restoring the previous hash"
  printf 'UPDATE account SET password=%s WHERE id=%s;\n' "'$old_hash'" "'$old_id'" | psql_stdin >/dev/null
  die "the hash reimplementation does not match what this app expects.
  The previous hash has been put back from $backup, so nothing is lost.
  The remaining route is to reset the password through the app itself."
}

case "${1:-}" in
  show)   cmd_show ;;
  check)  cmd_check ;;
  repair) cmd_repair ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  show     what is in 1Password, what is in the database, and when the
           credential was last written (read-only, prints no values)
  check    actually sign in with the stored password and say whether it works
  repair   rewrite the demo admin's hash to the 1Password value, then prove it
           by signing in; restores the old hash automatically if it does not

  env      TRACKER_ENV (default staging-ovh), TRACKER_URL, OP_ITEM, OP_VAULT

Needs an interactive 1Password session:  eval \$(op signin)
EOF
    exit 1 ;;
esac
