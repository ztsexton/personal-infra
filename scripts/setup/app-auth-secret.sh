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
field_shape() { # item
  op item get "$1" --vault "$VAULT" --format json 2>/dev/null | ITEM_FIELD="$FIELD" "$PY" -c '
import json, os, sys
want = os.environ["ITEM_FIELD"]
d = json.load(sys.stdin)
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
  # Trap rather than a trailing rm: on any failure below, `set -e` would exit
  # and leave the secret sitting in /tmp.
  trap 'rm -f "$tmpl"' RETURN

  if item_exists "$item"; then
    # Edit in place, preserving everything else on the item.
    op item get "$item" --vault "$VAULT" --format json > "$tmpl.orig" 2>/dev/null
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
    op item create --vault "$VAULT" - < "$tmpl" >/dev/null || rc=$?
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
  write_field "$item" "$(generate)"

  # Read back rather than trusting the exit code: `op item edit` has been seen
  # to exit 0 having changed nothing.
  local shape; shape=$(field_shape "$item")
  [ "$shape" != "ABSENT" ] && [ "$shape" != "PRESENT BUT EMPTY" ] \
    || die "wrote the field but reading it back says '$shape'"
  green "created. $FIELD is $shape (value not shown)"
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
