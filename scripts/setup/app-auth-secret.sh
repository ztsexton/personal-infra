#!/usr/bin/env bash
# Create or rotate an app's session-signing secret in 1Password.
#
#   ./scripts/setup/app-auth-secret.sh show    [item]
#   ./scripts/setup/app-auth-secret.sh create  [item]
#   ./scripts/setup/app-auth-secret.sh rotate  [item]
#
# Default item: ballroom-progress-tracker-auth, holding BETTER_AUTH_SECRET for
# k8s/apps/overlays/staging/ballroom-progress-tracker.
#
# The value is generated here and never leaves this machine except into the
# vault: nothing prints it, and the OnePasswordItem CR in git carries only the
# item's path. The operator syncs it into the cluster, so this is the only
# place it is ever written by hand.
#
# `rotate` is separate from `create` on purpose. Replacing this value
# invalidates every existing session -- everyone signed in is signed out -- so
# it should never happen as a side effect of running the wrong subcommand.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

VAULT="${OP_VAULT:-Kubernetes}"
ITEM_DEFAULT="ballroom-progress-tracker-auth"

# Every generated secret the tracker needs, in one item. The 1Password operator
# turns each field into a key of the same-named Kubernetes secret, so adding a
# field here is all it takes to make it available to a pod.
#
#   BETTER_AUTH_SECRET  session signing; rotating it signs everyone out
#   SEED_ADMIN_PASSWORD the owner account the seed creates, so staging has a
#                       real login rather than only @example.com fixtures
FIELDS=(BETTER_AUTH_SECRET SEED_ADMIN_PASSWORD)
FIELD="${FIELDS[0]}"
PY="${PY:-python3}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

# `op account list` exits 0 with no session, so it cannot be the test.
need_session() {
  command -v op >/dev/null || die "1Password CLI not installed"
  op whoami >/dev/null 2>&1 || die "no active 1Password session in this shell -- run: eval \$(op signin)"
}

item_exists() { op item get "$1" --vault "$VAULT" >/dev/null 2>&1; }

# Length only. This script exists to be run while someone watches the screen.
#
# Reports rather than crashes when op returns nothing. An empty stdin fed to
# json.load raises "Expecting value: line 1 column 1", which says nothing about
# the actual problem -- and this runs as the read-back after a write, so a
# traceback here reads as if the write itself exploded.
field_shape() { # item
  local out err rc=0
  err=$(mktemp)
  out=$(op item get "$1" --vault "$VAULT" --format json 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # Surface op's own words. Swallowing them was why the first failure here
    # was a Python traceback rather than a message naming the cause.
    printf 'UNREADABLE (%s)' "$(tr -d '\n' < "$err" | head -c 120)"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  printf '%s' "$out" | ITEM_FIELD="$FIELD" "$PY" -c '
import json, os, sys
want = os.environ["ITEM_FIELD"]
raw = sys.stdin.read().strip()
if not raw:
    print("UNREADABLE (op returned nothing)"); sys.exit()
try:
    d = json.loads(raw)
except json.JSONDecodeError as e:
    print("UNREADABLE (not JSON: %s)" % e); sys.exit()
for f in d.get("fields", []):
    if (f.get("label") or f.get("id")) == want:
        v = f.get("value") or ""
        print("%d chars" % len(v) if v else "PRESENT BUT EMPTY")
        sys.exit()
print("ABSENT")'
}

# 32 random bytes, base64 -- what the app documents for this value.
generate() { openssl rand -base64 32; }

cmd_show() {
  need_session
  local item="${1:-$ITEM_DEFAULT}"
  step "item '$item' in vault '$VAULT'"
  if ! item_exists "$item"; then
    warn "  does not exist yet -- create it with: $0 create $item"
    echo
    # A create that lost its title lands as an untitled item holding a real
    # secret, and `op item get <name>` will never find it. List the vault so a
    # stray one is visible rather than left to be discovered by accident.
    step "everything in vault '$VAULT', so a mistitled item is not missed"
    op item list --vault "$VAULT" --format json 2>/dev/null | "$PY" -c '
import json, sys
items = json.load(sys.stdin)
if not items:
    print("  (vault is empty)")
for i in items:
    t = (i.get("title") or "").strip()
    print("  %-44s %s" % (t if t else "<UNTITLED -- likely a failed create>", i.get("category","")))'
    return 0
  fi
  local f
  for f in "${FIELDS[@]}"; do
    FIELD="$f" printf '  %-22s %s\n' "$f" "$(FIELD="$f" field_shape "$item")"
  done
  echo
  echo "  The cluster reads this through the OnePasswordItem CR at"
  echo "  k8s/apps/overlays/staging/ballroom-progress-tracker/onepassword-secret.yaml"
}

# Write the value with an assignment statement.
#
# The JSON-template route was tried first, to keep the secret out of this
# process's command line where /proc exposes it. It does not work: op parses
# --title and --category before it reads stdin, and it does not apply the
# template's `fields` at all -- the item was created correctly named and
# completely empty. Five attempts, five different failures.
#
# So this uses the documented assignment form, which is what 1Password's own
# examples use and what works. The trade-off is real and worth naming: the
# value appears in the argument list for the fraction of a second op runs, and
# on a single-user machine that is an acceptable price for a command that
# actually stores the secret. Anything reading /proc here can already read the
# vault session.
write_field() { # item value  -- creates or edits as needed
  local item="$1" value="$2" rc=0

  if item_exists "$item"; then
    op item edit "$item" --vault "$VAULT" --dry-run "$FIELD[password]=$value" >/dev/null \
      || die "op rejected the edit; nothing was written."
    op item edit "$item" --vault "$VAULT" "$FIELD[password]=$value" >/dev/null || rc=$?
  else
    # Secure Note rather than Password: op validates the whole item on edit, and
    # a Password item with an empty password field fails that validation later
    # even when the edit does not touch it.
    op item create --category "Secure Note" --title "$item" --vault "$VAULT" \
      --dry-run "$FIELD[password]=$value" >/dev/null \
      || die "op rejected the create; nothing was written."
    op item create --category "Secure Note" --title "$item" --vault "$VAULT" \
      "$FIELD[password]=$value" >/dev/null || rc=$?
  fi
  return $rc
}

cmd_create() {
  need_session
  local item="${1:-$ITEM_DEFAULT}" f shape wrote=0

  for f in "${FIELDS[@]}"; do
    shape=$(FIELD="$f" field_shape "$item")
    case "$shape" in
      *chars)
        # Already set. Not an error -- this command is safe to re-run when a
        # new field is added to FIELDS, which is the usual reason to run it
        # twice.
        green "$f already set ($shape); leaving it alone"
        continue ;;
      UNREADABLE*)
        # Only when the item itself is missing; a real read failure is fatal.
        item_exists "$item" && die "cannot read $f on '$item': $shape" ;;
    esac
    step "generating $f and writing it to '$item'"
    FIELD="$f" write_field "$item" "$(generate)" || die "the write failed; see op's message above"
    wrote=1
  done

  [ "$wrote" = "1" ] || { green "nothing to do -- every field is already set"; return 0; }

  # Read back rather than trusting the exit code: `op item edit` has been seen
  # to exit 0 having changed nothing.
  # Only a length counts as success. UNREADABLE previously passed this check,
  # so the script announced "created" while telling you in the same sentence
  # that it could not find the item.
  for f in "${FIELDS[@]}"; do
    shape=$(FIELD="$f" field_shape "$item")
    case "$shape" in
      *chars) green "$f is $shape (value not shown)" ;;
      *) die "the write reported success but reading $f back says: $shape" ;;
    esac
  done
  echo
  echo "The operator syncs it within a minute. Confirm with:"
  echo "  KUBECONFIG=$REPO/kubeconfig-staging-ovh.yaml ./scripts/secrets.sh status"
}

cmd_rotate() {
  need_session
  local item="${1:-$ITEM_DEFAULT}"
  FIELD="${2:-$FIELD}"
  item_exists "$item" || die "'$item' does not exist -- use: $0 create $item"

  warn "Rotating $FIELD on '$item'."
  warn "Every signed-in session becomes invalid immediately. Nobody stays"
  warn "logged in, and there is no way back to the old value."
  read -r -p "Type 'rotate' to continue: " reply
  [ "$reply" = "rotate" ] || die "aborted"

  local before; before=$(field_shape "$item")
  write_field "$item" "$(generate)"
  local after; after=$(field_shape "$item")
  [ "$after" != "ABSENT" ] || die "the field is gone after the edit -- check the item by hand"

  green "rotated ($before -> $after; values not shown)"
  echo
  echo "The operator updates the k8s secret, but running pods hold the old value"
  echo "until they restart:"
  echo "  kubectl -n web rollout restart deploy ballroom-progress-tracker"
}

case "${1:-}" in
  show)   shift; cmd_show "$@" ;;
  create) shift; cmd_create "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  *)
    cat >&2 <<EOF
usage: $0 <command> [item] [field]

  show            which fields exist and how long each value is
  create          generate any missing field and store it; existing ones are
                  left alone, so it is safe to re-run when a field is added
  rotate [field]  replace one field -- rotating BETTER_AUTH_SECRET signs out
                  every session

Fields: ${FIELDS[*]}
Item defaults to "$ITEM_DEFAULT", vault to "$VAULT" (override with OP_VAULT).
EOF
    exit 1 ;;
esac
