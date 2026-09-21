#!/usr/bin/env bash
# The Argo CD admin credential, with 1Password as the source of truth.
#
#   ./scripts/setup/argocd-admin-secret.sh show   <env>
#   ./scripts/setup/argocd-admin-secret.sh create <env>
#   ./scripts/setup/argocd-admin-secret.sh rotate <env>
#   ./scripts/setup/argocd-admin-secret.sh adopt  <env>
#   ./scripts/setup/argocd-admin-secret.sh verify <env>
#
# Argo CD reads the admin password from exactly one place: the argocd-secret
# Secret, keys admin.password (bcrypt) and admin.passwordMtime. There is no
# valueFrom indirection and no second location it will look in. So "the password
# comes from 1Password" necessarily means the 1Password operator OWNS
# argocd-secret -- a OnePasswordItem CR named argocd-secret, whose 1Password
# item's field labels become that Secret's keys.
#
# Two consequences, both sharp:
#
#   1. The item must carry EVERY key argocd-secret holds, not just the password.
#      The operator replaces the Secret's data wholesale, so a key missing from
#      the item is a key deleted from the cluster. server.secretkey signs session
#      JWTs; drop it and every session dies. Production also keeps tls.crt and
#      tls.key there. `create` therefore copies every existing key out of the
#      live cluster into the item verbatim, rather than assuming which ones
#      exist -- that assumption is the whole failure mode.
#
#   2. The Secret gets ownerReferences pointing at the OnePasswordItem. Delete
#      the CR -- or let Argo CD prune it -- and Kubernetes garbage-collects
#      argocd-secret along with it, taking the admin password and the session key
#      with it. The root Application runs with prune: true, so deleting the
#      manifest from git is enough to trigger that.
#
# Two 1Password items, deliberately:
#
#   argocd-admin-<env>   machine-readable: bcrypt hash and session key. This is
#                        the one the operator syncs into the cluster. No
#                        plaintext password ever reaches Kubernetes.
#   Argo CD (<env>)      the login humans use: username, password, URL.
#
# The plaintext exists only in the second item, and nothing can recover it from
# the first. That is the point of the split, and it means losing the login item
# means rotating, not recovering.
#
# Requires an interactive 1Password session in this shell:  eval $(op signin)
set -euo pipefail

export PATH="$HOME/bin:$PATH"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PY:-$REPO/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

VAULT="${OP_VAULT:-Kubernetes}"
BACKUP_DIR="${PASSWORD_BACKUP_DIR:-$REPO/.argocd-backups}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

# --- environment ---------------------------------------------------------------
#
# Hetzner staging and OVH staging are two clusters that sync the same git path
# (k8s/argocd/staging), so they share one item. Only one of them exists at a
# time; giving them separate credentials would mean the manifest could only ever
# be right for one.
ENV_NAME=""
KUBECONFIG_PATH=""
ITEM=""
LOGIN_ITEM=""
ARGOCD_URL=""

resolve_env() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in
    staging|staging-ovh)
      ITEM="argocd-admin-staging"
      LOGIN_ITEM="Argo CD (staging)"
      ARGOCD_URL="https://argocd-staging.zachsexton.com" ;;
    production)
      ITEM="argocd-admin-production"
      LOGIN_ITEM="Argo CD (production)"
      ARGOCD_URL="https://argocd.zachsexton.com" ;;
    *)
      die "unknown environment '${ENV_NAME:-}' -- expected: staging-ovh, staging, production" ;;
  esac
  KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-$ENV_NAME.yaml}"
}

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" -n argocd --request-timeout=15s "$@"; }

need_session() {
  command -v op >/dev/null || die "the 1Password CLI is not on PATH"
  # `op account list` exits 0 for a merely configured account; only whoami needs
  # a live session.
  op whoami >/dev/null 2>&1 || die "no active 1Password session in this shell -- run: eval \$(op signin)"
}

need_cluster() {
  [ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH"
  # A wall-clock cap as well as --request-timeout: the latter bounds the HTTP
  # request, not the TCP connect, so a kubeconfig that outlived its cluster
  # hangs for over a minute instead of failing.
  timeout 20 kubectl --kubeconfig "$KUBECONFIG_PATH" get ns --request-timeout=15s >/dev/null 2>&1 \
    || die "cannot reach the cluster with $KUBECONFIG_PATH"
}

bcrypt_available() { "$PY" -c 'import bcrypt' >/dev/null 2>&1; }

bcrypt_hash() {
  local pass="$1" h
  if command -v htpasswd >/dev/null 2>&1; then
    h=$(htpasswd -nbBC 10 admin "$pass" | cut -d: -f2)
  elif bcrypt_available; then
    h=$("$PY" -c 'import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' "$pass")
  else
    die "no way to bcrypt here -- install apache2-utils (htpasswd) or python3 bcrypt"
  fi
  printf '%s\n' "$h" | sed 's/^\$2y\$/\$2a\$/'
}

# 0 = matches, 1 = does not, 2 = cannot tell.
bcrypt_check() {
  local pass="$1" hash="$2"
  if bcrypt_available; then
    "$PY" -c 'import bcrypt, sys
sys.exit(0 if bcrypt.checkpw(sys.argv[1].encode(), sys.argv[2].encode()) else 1)' "$pass" "$hash"
  elif command -v htpasswd >/dev/null 2>&1; then
    local f rc=0
    f=$(mktemp); chmod 600 "$f"
    printf 'admin:%s\n' "$hash" >"$f"
    htpasswd -bv "$f" admin "$pass" >/dev/null 2>&1 || rc=1
    rm -f "$f"
    return $rc
  else
    return 2
  fi
}

new_password() {
  "$PY" -c 'import secrets, string
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))'
}

# --- the live Secret -----------------------------------------------------------

# key<TAB>base64value, one record per line, for every key in argocd-secret.
#
# The values stay base64 the whole way through this script and are decoded only
# at the moment of use. argocd-secret holds PEMs -- production keeps tls.crt and
# tls.key there -- and a PEM contains newlines, so the obvious key<TAB>value
# format makes every line of a certificate parse as its own key. That is not a
# cosmetic bug: `create` would build an item whose fields were PEM fragments and
# which did NOT carry tls.crt, and syncing that item would delete the real key
# from the cluster.
#
# Empty (not a failure) when the Secret is absent, because "it is not there" is
# something the callers report rather than an error.
secret_entries() {
  k get secret argocd-secret -o json 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key, val in sorted((d.get("data") or {}).items()):
    sys.stdout.write("%s\t%s\n" % (key, "".join(val.split())))' || true
}

# Decode a base64 value into the variable named by $1.
#
# Not `var=$(... | base64 -d)`: command substitution strips trailing newlines,
# and a PEM ends with one. Round-tripping tls.key through that would hand
# 1Password a value one byte different from what the cluster had.
b64_into() { # varname base64
  local __decoded
  IFS= read -r -d "" __decoded < <(printf '%s' "$2" | base64 -d 2>/dev/null; printf '\0') || true
  printf -v "$1" '%s' "$__decoded"
}

# The decoded value of one key, for callers that only need to compare or measure
# it. Single-line values only -- use b64_into where exactness matters.
secret_value() { # key
  local b64
  b64=$(secret_entries | awk -F'\t' -v k="$1" '$1==k {print $2; exit}')
  [ -n "$b64" ] || return 0
  printf '%s' "$b64" | base64 -d 2>/dev/null || true
}

secret_owner() {
  k get secret argocd-secret -o json 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("absent"); sys.exit(0)
m = d.get("metadata", {})
for o in (m.get("ownerReferences") or []):
    if o.get("kind") == "OnePasswordItem":
        ann = m.get("annotations") or {}
        print("onepassword item-version=%s" % ann.get("operator.1password.io/item-version", "?"))
        sys.exit(0)
ann = m.get("annotations") or {}
if "kubectl.kubernetes.io/last-applied-configuration" in ann:
    print("kubectl")
elif (m.get("labels") or {}).get("app.kubernetes.io/managed-by") == "Helm":
    print("helm")
else:
    print("unmanaged")' || echo absent
}

# --- the 1Password item --------------------------------------------------------

item_exists() { op item get "$1" --vault "$VAULT" >/dev/null 2>&1; }

# label<TAB>base64value for every field. Base64 for the same reason the Secret
# side uses it: a field holding a PEM would otherwise span lines and every line
# would read as another field.
item_entries() {
  op item get "$1" --vault "$VAULT" --format json --reveal 2>/dev/null | "$PY" -c '
import base64, json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for f in d.get("fields", []):
    label = f.get("label") or ""
    # notesPlain is the Secure Note body; it is not a secret key.
    if not label or label == "notesPlain":
        continue
    val = (f.get("value") or "").encode()
    sys.stdout.write("%s\t%s\n" % (label, base64.b64encode(val).decode()))' || true
}

item_entry_b64() { item_entries "$1" | awk -F'\t' -v l="$2" '$1==l {print $2; exit}'; }

# Decoded, for comparisons and emptiness checks.
item_field() { # item label
  local b64; b64=$(item_entry_b64 "$1" "$2")
  [ -n "$b64" ] || return 0
  printf '%s' "$b64" | base64 -d 2>/dev/null || true
}

# op parses a field assignment as [<section>.]<field>=value, so every period that
# is part of a name rather than the separator must be escaped or op reads
# "admin.password" as the field "password" inside a section "admin" -- which
# would then sync into the cluster under the key "password" and never be read by
# Argo CD. registry-auth.sh hit the same edge on ".dockerconfigjson".
esc_label() { printf '%s' "$1" | sed 's/\./\\./g'; }

# op exits 0 having written nothing when a field address does not match, so a
# write is only believed once the value is read back.
fingerprint() {
  op item get "$1" --vault "$VAULT" --format json 2>/dev/null | "$PY" -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("|".join(str(d.get(k, "")) for k in ("updated_at", "updatedAt", "version")).strip("|"))' || true
}

# --- commands ------------------------------------------------------------------

cmd_show() {
  need_session
  step "1Password ($VAULT)"
  if item_exists "$ITEM"; then
    printf '  %-26s exists\n' "$ITEM"
    while IFS=$'\t' read -r label b64; do
      [ -n "$label" ] || continue
      local decoded; b64_into decoded "$b64"
      printf '    %-24s %d chars\n' "$label" "${#decoded}"
    done < <(item_entries "$ITEM")
  else
    printf '  %-26s MISSING -- run: %s create %s\n' "$ITEM" "$0" "$ENV_NAME"
  fi
  if item_exists "$LOGIN_ITEM"; then
    printf '  %-26s exists (the human login)\n' "$LOGIN_ITEM"
  else
    printf '  %-26s MISSING (the human login)\n' "$LOGIN_ITEM"
  fi

  echo
  step "cluster ($ENV_NAME)"
  if ! timeout 20 kubectl --kubeconfig "$KUBECONFIG_PATH" get ns --request-timeout=15s >/dev/null 2>&1; then
    warn "  unreachable with $KUBECONFIG_PATH -- skipping"
    return 0
  fi
  printf '  argocd-secret written by: %s\n' "$(secret_owner)"
  while IFS=$'\t' read -r key b64; do
    [ -n "$key" ] || continue
    local decoded; b64_into decoded "$b64"
    printf '    %-24s %d chars\n' "$key" "${#decoded}"
  done < <(secret_entries)

  echo
  echo "Values are never printed. Compare the key names above: the item must carry"
  echo "every key the Secret has, or syncing it will delete the ones it lacks."
}

# Build the item from the live Secret plus a new password. Every key that is not
# the password is copied across untouched, so nothing can be dropped by having
# guessed the wrong set.
cmd_create() {
  need_session
  need_cluster

  item_exists "$ITEM" && die "'$ITEM' already exists in vault '$VAULT' -- use: $0 rotate $ENV_NAME"

  step "reading the live argocd-secret"
  local entries; entries=$(secret_entries)
  [ -n "$entries" ] || die "argocd-secret has no data on $ENV_NAME -- nothing to preserve, and an
  item built from nothing would delete the Secret's contents on first sync"

  local carried=() assigns=() label b64 value
  while IFS=$'\t' read -r label b64; do
    [ -n "$label" ] || continue
    case "$label" in
      admin.password|admin.passwordMtime) continue ;;  # replaced below
    esac
    carried+=("$label")
    b64_into value "$b64"
    assigns+=("$(esc_label "$label")[password]=$value")
  done <<<"$entries"

  printf '  carrying across untouched: %s\n' "${carried[*]:-<none>}"
  case " ${carried[*]} " in
    *" server.secretkey "*) ;;
    *) warn "  server.secretkey is NOT in the live Secret; sessions will be re-keyed on sync" ;;
  esac

  local pass hash mtime
  pass=$(new_password)
  hash=$(bcrypt_hash "$pass")
  mtime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  assigns+=("$(esc_label admin.password)[text]=$hash")
  assigns+=("$(esc_label admin.passwordMtime)[text]=$mtime")

  step "creating '$ITEM' in vault '$VAULT'"
  # Secure Note, not Password: op validates a PASSWORD item on every edit and
  # refuses to save one whose password field is empty, which makes later
  # rotations fail for a reason that has nothing to do with the rotation.
  op item create --category "Secure Note" --title "$ITEM" --vault "$VAULT" "${assigns[@]}" >/dev/null \
    || die "op item create failed"

  # Read back rather than trust the exit code.
  local missing=()
  for label in "${carried[@]}" admin.password admin.passwordMtime; do
    [ -n "$(item_field "$ITEM" "$label")" ] || missing+=("$label")
  done
  [ "${#missing[@]}" -eq 0 ] || die "created '$ITEM' but these fields did not land: ${missing[*]}
  delete the item and re-run; syncing it as-is would delete those keys from the cluster"
  green "  all $(( ${#carried[@]} + 2 )) fields verified present"

  step "creating the human login '$LOGIN_ITEM'"
  if item_exists "$LOGIN_ITEM"; then
    warn "  already exists -- updating its password instead"
    op item edit "$LOGIN_ITEM" --vault "$VAULT" "password=$pass" "username=admin" >/dev/null \
      || die "op item edit failed for '$LOGIN_ITEM'"
  else
    op item create --category Login --title "$LOGIN_ITEM" --vault "$VAULT" \
      "username=admin" "password=$pass" --url "$ARGOCD_URL" >/dev/null \
      || die "op item create failed for '$LOGIN_ITEM'"
  fi
  [ "$(op item get "$LOGIN_ITEM" --vault "$VAULT" --fields password --reveal 2>/dev/null | tr -d '\n')" = "$pass" ] \
    || die "'$LOGIN_ITEM' does not read back the password that was just written"
  green "  stored, and reads back correctly"

  echo
  step "the new password"
  printf '  username: admin\n'
  printf '  password: %s\n' "$pass"
  warn "It is in 1Password as '$LOGIN_ITEM'. It is NOT in the cluster yet."
  echo
  echo "The cluster still has the old password. It changes when the operator takes"
  echo "over argocd-secret:"
  echo "  1. commit and push k8s/argocd/staging/argocd-secret.yaml"
  echo "  2. $0 verify $ENV_NAME"
  echo "  3. if the operator will not overwrite a Secret it does not own:"
  echo "     $0 adopt $ENV_NAME"
}

cmd_rotate() {
  need_session
  item_exists "$ITEM" || die "'$ITEM' does not exist in vault '$VAULT' -- use: $0 create $ENV_NAME"

  warn "This changes the Argo CD admin password for $ENV_NAME."
  warn "It takes effect when the operator next syncs, not immediately."
  read -r -p "Type 'rotate' to continue: " reply
  [ "$reply" = "rotate" ] || die "aborted"

  local pass hash mtime before after
  pass=$(new_password)
  hash=$(bcrypt_hash "$pass")
  mtime=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  before=$(fingerprint "$ITEM")
  op item edit "$ITEM" --vault "$VAULT" \
    "$(esc_label admin.password)[text]=$hash" \
    "$(esc_label admin.passwordMtime)[text]=$mtime" >/dev/null \
    || die "op item edit failed"
  after=$(fingerprint "$ITEM")

  [ "$(item_field "$ITEM" admin.password)" = "$hash" ] \
    || die "'$ITEM' does not read back the new hash -- the write did not land"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    die "'$ITEM' was not modified (unchanged at $before) -- the write did not land"
  fi
  green "hash updated in '$ITEM'"

  op item edit "$LOGIN_ITEM" --vault "$VAULT" "password=$pass" >/dev/null \
    || die "op item edit failed for '$LOGIN_ITEM'"
  [ "$(op item get "$LOGIN_ITEM" --vault "$VAULT" --fields password --reveal 2>/dev/null | tr -d '\n')" = "$pass" ] \
    || die "'$LOGIN_ITEM' does not read back the new password"
  green "plaintext updated in '$LOGIN_ITEM'"

  echo
  printf '  username: admin\n'
  printf '  password: %s\n' "$pass"
  echo
  echo "The operator picks this up on its next poll. Confirm with:"
  echo "  $0 verify $ENV_NAME"
}

# The operator creates Secrets; it does not necessarily take over one that
# already exists and carries someone else's ownership. Deleting the Secret lets
# it build a clean one -- safe ONLY because the item already carries every key,
# which is checked here rather than assumed.
cmd_adopt() {
  need_session
  need_cluster

  item_exists "$ITEM" || die "'$ITEM' does not exist -- run: $0 create $ENV_NAME"

  step "checking the item covers every key in the live Secret"
  local entries missing=() key value
  entries=$(secret_entries)
  [ -n "$entries" ] || die "argocd-secret is absent or empty; nothing to adopt"
  while IFS=$'\t' read -r key _b64; do
    [ -n "$key" ] || continue
    [ -n "$(item_entry_b64 "$ITEM" "$key")" ] || missing+=("$key")
  done <<<"$entries"
  if [ "${#missing[@]}" -gt 0 ]; then
    die "'$ITEM' is missing these keys the cluster currently has: ${missing[*]}
  deleting the Secret now would lose them permanently. Add them to the item first."
  fi
  green "  every key present in the item"

  local owner; owner=$(secret_owner)
  case "$owner" in
    onepassword*) green "argocd-secret is already operator-owned ($owner) -- nothing to adopt"; return 0 ;;
  esac

  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local backup="$BACKUP_DIR/argocd-secret-$ENV_NAME-$(date -u +%Y%m%dT%H%M%SZ).yaml"
  ( umask 077; k get secret argocd-secret -o yaml >"$backup" )
  green "backed up argocd-secret to $backup"

  echo
  warn "About to DELETE argocd-secret on $ENV_NAME so the operator recreates it."
  warn "Argo CD logs everyone out and admin login stops working until the operator"
  warn "syncs (usually seconds). Restore from the backup above if it does not."
  read -r -p "Type 'adopt' to continue: " reply
  [ "$reply" = "adopt" ] || die "aborted"

  k delete secret argocd-secret >/dev/null
  step "waiting for the operator to recreate it"
  local i owner_now=""
  for i in $(seq 1 60); do
    sleep 2
    owner_now=$(secret_owner)
    case "$owner_now" in
      onepassword*) break ;;
    esac
    printf '.'
  done
  echo
  case "$owner_now" in
    onepassword*) green "recreated and owned by the operator ($owner_now)" ;;
    *) red "the operator has not recreated argocd-secret after 120s (state: $owner_now)"
       red "restore it now with:"
       red "  kubectl --kubeconfig $KUBECONFIG_PATH -n argocd apply -f $backup"
       exit 1 ;;
  esac

  echo
  cmd_verify
}

cmd_verify() {
  need_session
  need_cluster

  step "1Password vs the cluster ($ENV_NAME)"
  item_exists "$ITEM" || die "'$ITEM' does not exist in vault '$VAULT'"

  local owner; owner=$(secret_owner)
  printf '  argocd-secret written by: %s\n' "$owner"

  # Every key the Secret has must exist in the item, or the next sync deletes it.
  local entries missing=() key value
  entries=$(secret_entries)
  while IFS=$'\t' read -r key _b64; do
    [ -n "$key" ] || continue
    [ -n "$(item_entry_b64 "$ITEM" "$key")" ] || missing+=("$key")
  done <<<"$entries"
  if [ "${#missing[@]}" -gt 0 ]; then
    red "  keys in the cluster but NOT in the item: ${missing[*]}"
    red "  the next operator sync would delete them"
  else
    green "  the item covers every key the Secret has"
  fi

  # Does the hash in the cluster match the hash in the item?
  local live_hash item_hash
  live_hash=$(secret_value admin.password)
  item_hash=$(item_field "$ITEM" admin.password)
  if [ -z "$live_hash" ]; then
    red "  the cluster Secret has no admin.password"
  elif [ "$live_hash" = "$item_hash" ]; then
    green "  the cluster is running the hash from 1Password"
  else
    warn "  the cluster's hash differs from the item's -- the operator has not synced it yet"
  fi

  # The end-to-end proof: does the plaintext a human would type actually match
  # the hash the cluster is running? Everything above can look right while this
  # is wrong.
  if item_exists "$LOGIN_ITEM"; then
    local plaintext rc=0
    plaintext=$(op item get "$LOGIN_ITEM" --vault "$VAULT" --fields password --reveal 2>/dev/null | tr -d '\n')
    if [ -n "$plaintext" ] && [ -n "$live_hash" ]; then
      bcrypt_check "$plaintext" "$live_hash" || rc=$?
      case "$rc" in
        0) green "  the password in '$LOGIN_ITEM' logs into $ENV_NAME" ;;
        1) red   "  the password in '$LOGIN_ITEM' does NOT match what the cluster runs" ;;
        *) warn  "  could not check the login (no bcrypt available)" ;;
      esac
    fi
  else
    warn "  '$LOGIN_ITEM' does not exist -- no human-usable login is stored"
  fi

  echo
  printf '  URL: %s\n' "$ARGOCD_URL"
}

SUB="${1:-}"; shift || true
case "$SUB" in
  show|create|rotate|adopt|verify)
    resolve_env "${1:-}"
    "cmd_$(printf '%s' "$SUB")" ;;
  *)
    cat >&2 <<EOF
usage: $0 <command> <env>

  show     what is in 1Password, what is in the cluster, and whether the key
           names line up (read-only, prints no values)
  create   generate a password, build the 1Password item from the LIVE Secret so
           no key is dropped, and store the human login separately
  rotate   new password into both items; takes effect on the operator's next sync
  adopt    delete argocd-secret so the operator rebuilds it as owner -- only
           after checking the item carries every key, and with a backup
  verify   is the cluster actually running the 1Password value, and does the
           stored login actually work

  env      staging-ovh | staging | production

Needs an interactive 1Password session:  eval \$(op signin)
EOF
    exit 1 ;;
esac
