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

# Temp files that may hold the secret. A single EXIT trap removes them however
# the script ends. A `trap ... RETURN` inside a function is NOT scoped to that
# function -- it stays installed and fires again when the caller returns, where
# its variables no longer exist.
TMPFILES=()
cleanup_tmpfiles() { [ "${#TMPFILES[@]}" -gt 0 ] && rm -f "${TMPFILES[@]}" || true; }
trap cleanup_tmpfiles EXIT
VAULT="${OP_VAULT:-Kubernetes}"
ITEM_DEFAULT="ballroom-progress-tracker-auth"
FIELD="BETTER_AUTH_SECRET"
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
  printf '  %-22s %s\n' "$FIELD" "$(field_shape "$item")"
  echo
  echo "  The cluster reads this through the OnePasswordItem CR at"
  echo "  k8s/apps/overlays/staging/ballroom-progress-tracker/onepassword-secret.yaml"
}

# Write the value through a JSON template, never an assignment argument.
#
# `op item edit BETTER_AUTH_SECRET=<value>` puts the secret in this process's
# command line, where every other process on the machine can read it from
# /proc/<pid>/cmdline for as long as the call runs. 1Password's own help says
# so plainly: "For sensitive values, use a template instead."
#
# Both create and edit accept a template, so the value goes from openssl to a
# 0600 file to op, and never appears as an argument.
write_field() { # item value  -- creates or edits as needed
  local item="$1" value="$2" tmpl rc=0
  tmpl=$(mktemp); chmod 600 "$tmpl"
  TMPFILES+=("$tmpl" "$tmpl.orig")

  if item_exists "$item"; then
    # Edit in place, preserving everything else on the item.
    op item get "$item" --vault "$VAULT" --format json > "$tmpl.orig" \
      || die "could not read the existing item '$item' -- op's message is above"
    [ -s "$tmpl.orig" ] || die "op returned an empty item for '$item'; refusing to overwrite it with a guess"
    ITEM_FIELD="$FIELD" VALUE="$value" "$PY" - "$tmpl.orig" > "$tmpl" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
want, val = os.environ["ITEM_FIELD"], os.environ["VALUE"]
for f in d.setdefault("fields", []):
    if (f.get("label") or f.get("id")) == want:
        f["value"] = val
        break
else:
    d["fields"].append({"id": want, "label": want,
                        "type": "CONCEALED", "value": val})
json.dump(d, sys.stdout)
PYEOF
    rm -f "$tmpl.orig"
    # Dry run first. Both subcommands support it, and it turns a malformed
    # invocation into a failure that changes nothing instead of one discovered
    # halfway through writing a secret.
    op item edit "$item" --vault "$VAULT" --template "$tmpl" --dry-run >/dev/null \
      || die "op rejected the edit; nothing was written. Re-run with OP_DEBUG=1 to see it."
    op item edit "$item" --vault "$VAULT" --template "$tmpl" >/dev/null || rc=$?
  else
    # A Secure Note rather than a Password item: op validates the whole item on
    # edit, and a Password item with an empty password field fails that
    # validation later even when the edit does not touch it.
    ITEM_FIELD="$FIELD" VALUE="$value" TITLE="$item" "$PY" - > "$tmpl" <<'PYEOF'
import json, os, sys
json.dump({
    "title": os.environ["TITLE"],
    "category": "SECURE_NOTE",
    "fields": [{"id": os.environ["ITEM_FIELD"],
                "label": os.environ["ITEM_FIELD"],
                "type": "CONCEALED",
                "value": os.environ["VALUE"]}],
}, sys.stdout)
PYEOF
    # --category is required even though the template carries one: op parses
    # the flag before it reads stdin, and refuses with "provide the item
    # category with '--category' flag" otherwise.
    # --title for the same reason as --category: op parses its flags before it
    # reads stdin, so the template's "title" is not seen in time. Without it the
    # item is created untitled and `op item get <name>` cannot find it -- which
    # is exactly what happened: create reported success and the read-back said
    # the item was not in the vault.
    op item create --category "Secure Note" --title "$item" --vault "$VAULT" \
      --dry-run - < "$tmpl" >/dev/null \
      || die "op rejected the create; nothing was written."
    op item create --category "Secure Note" --title "$item" --vault "$VAULT" \
      - < "$tmpl" >/dev/null || rc=$?
  fi
  return $rc
}

cmd_create() {
  need_session
  local item="${1:-$ITEM_DEFAULT}"
  if item_exists "$item"; then
    local shape; shape=$(field_shape "$item")
    if [ "$shape" != "ABSENT" ] && [ "$shape" != "PRESENT BUT EMPTY" ]; then
      warn "'$item' already has $FIELD ($shape)."
      warn "Replacing it signs out every existing session. If that is what you"
      warn "want, use: $0 rotate $item"
      exit 1
    fi
  fi

  step "generating $FIELD and writing it to '$item'"
  write_field "$item" "$(generate)" || die "the write failed; see op's message above"

  # Read back rather than trusting the exit code: `op item edit` has been seen
  # to exit 0 having changed nothing.
  # Only a length counts as success. UNREADABLE previously passed this check,
  # so the script announced "created" while telling you in the same sentence
  # that it could not find the item.
  local shape; shape=$(field_shape "$item")
  case "$shape" in
    *chars) green "created. $FIELD is $shape (value not shown)" ;;
    *) die "the write reported success but reading it back says: $shape" ;;
  esac
  echo
  echo "The operator syncs it within a minute. Confirm with:"
  echo "  KUBECONFIG=$REPO/kubeconfig-staging-ovh.yaml ./scripts/secrets.sh status"
}

cmd_rotate() {
  need_session
  local item="${1:-$ITEM_DEFAULT}"
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
usage: $0 <command> [item]

  show     whether the item and field exist, and how long the value is
  create   generate the secret and store it (refuses if one already exists)
  rotate   replace an existing secret -- signs out every session

Item defaults to "$ITEM_DEFAULT", vault to "$VAULT" (override with OP_VAULT).
EOF
    exit 1 ;;
esac
