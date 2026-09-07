#!/usr/bin/env bash
# Manage the private-registry pull credential stored in 1Password.
#
#   ./scripts/setup/registry-auth.sh show
#   ./scripts/setup/registry-auth.sh add-ghcr
#   ./scripts/setup/registry-auth.sh verify
#
# The `zot-docker-config` item's `.dockerconfigjson` field is the single source
# for the zot-registry-credentials pull secret. A OnePasswordItem CR
# (k8s/apps/base/registry-credentials) syncs it into every cluster, so editing it
# here is what changes the credential everywhere -- no kubectl involved.
#
# Keeping every registry the clusters pull from in one value is what makes a
# registry migration orderless: each environment keeps working against whichever
# registry its manifests currently name.
#
# Requires an interactive 1Password session in this shell:  eval $(op signin)
set -euo pipefail

export PATH="$HOME/bin:$PATH"

ITEM="${OP_ITEM:-zot-docker-config}"
PAT_ITEM="${OP_PAT_ITEM:-Personal Infra PAT Github Classic}"
# Only vaults that a OnePasswordItem CR actually references are worth editing.
# Every itemPath in k8s/ points at "Kubernetes"; Kubernetes-Staging exists but
# nothing reads it, so editing a copy there changes nothing in any cluster.
VAULTS=("${@:2}")
[ "${#VAULTS[@]}" -gt 0 ] || VAULTS=(Kubernetes)
FIELD='.dockerconfigjson'
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PY:-$REPO/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

need_session() {
  command -v op >/dev/null || die "the 1Password CLI is not on PATH"
  # `op account list` exits 0 for a merely configured account; only whoami needs
  # a live session.
  op whoami >/dev/null 2>&1 || die "no active 1Password session in this shell -- run: eval \$(op signin)"
}

# The field sits inside a section, and `--fields` may not match an unqualified
# name in that case. Read the whole item and pick the field out of the JSON
# instead, which does not depend on how op parses field addresses.
get_field() { # vault -> the raw .dockerconfigjson
  op item get "$ITEM" --vault "$1" --format json 2>/dev/null | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for f in d.get("fields", []):
    if f.get("label") == ".dockerconfigjson":
        sys.stdout.write(f.get("value") or ""); break'
}

registries_in() { # json on stdin
  "$PY" -c '
import sys, json
try:
    d = json.loads(sys.stdin.read().strip() or "{}")
    print(", ".join(sorted(d.get("auths", {}).keys())) or "(none)")
except Exception as e:
    print("unparseable: %s" % e)'
}

cmd_show() {
  need_session
  for v in "${VAULTS[@]}"; do
    printf '  %-22s ' "$v"
    get_field "$v" | registries_in
  done
  echo
  echo "Values are not printed. The pull secret is base64 of user:password, which"
  echo "is reversible -- treat it as the credential itself."
}

cmd_add_ghcr() {
  need_session

  step "reading the GitHub token from '$PAT_ITEM'"
  local user pat
  user=$(op item get "$PAT_ITEM" --vault "${VAULTS[0]}" --fields username --reveal 2>/dev/null | tr -d '\n')
  pat=$(op item get "$PAT_ITEM" --vault "${VAULTS[0]}" --fields password --reveal 2>/dev/null | tr -d '\n')
  [ -n "$user" ] && [ -n "$pat" ] || die "could not read username/password from '$PAT_ITEM'"

  case "$pat" in
    ghp_*) : ;;
    github_pat_*) die "that is a fine-grained token; GHCR needs a classic PAT (ghp_) with read:packages" ;;
    *) warn "token does not look like a classic PAT; continuing anyway" ;;
  esac

  for v in "${VAULTS[@]}"; do
    step "updating $ITEM in vault '$v'"
    local current merged
    if ! op item get "$ITEM" --vault "$v" >/dev/null 2>&1; then
      warn "  '$ITEM' does not exist in vault '$v' -- skipping"
      continue
    fi
    current=$(get_field "$v")
    [ -n "$current" ] || die "'$ITEM' in '$v' has no $FIELD field"
    printf '  before: '; echo "$current" | registries_in

    merged=$(OP_USER="$user" OP_PAT="$pat" "$PY" -c '
import sys, json, base64, os
cfg = json.loads(sys.stdin.read().strip())
cfg.setdefault("auths", {})["ghcr.io"] = {
    "auth": base64.b64encode(
        ("%s:%s" % (os.environ["OP_USER"], os.environ["OP_PAT"])).encode()
    ).decode()
}
print(json.dumps(cfg, separators=(",", ":")))' <<<"$current")

    # `op item edit` addresses fields as [section.]field=value. This field is
    # named ".dockerconfigjson" AND lives in a section, so the unqualified form
    # silently fails to match. The qualifier is read from the item rather than
    # assumed, since a field added through the 1Password UI lands in a section
    # called "add more" whose label is null.
    local target before_ts after_ts
    target=$(op item get "$ITEM" --vault "$v" --format json 2>/dev/null | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for f in d.get("fields", []):
    if f.get("label") == ".dockerconfigjson":
        sec = (f.get("section") or {}).get("id")
        print("%s.%s" % (sec, f["label"]) if sec else f["label"])
        break')
    [ -n "$target" ] || die "could not locate the .dockerconfigjson field in '$v'"
    echo "  field address: $target"

    # Fingerprint rather than one key: op's JSON has used both updated_at and
    # updatedAt across versions, and `version` increments on every edit. If none
    # of them are present the check is skipped rather than failing a good write.
    fingerprint() {
      op item get "$ITEM" --vault "$1" --format json 2>/dev/null | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("|".join(str(d.get(k, "")) for k in ("updated_at", "updatedAt", "version")).strip("|"))'
    }
    before_ts=$(fingerprint "$v")

    op item edit "$ITEM" --vault "$v" "$target=$merged" >/dev/null \
      || die "op item edit failed for vault '$v'"

    # Two independent checks. The value could look right while the item was never
    # written -- which is exactly what happened when the field address was wrong:
    # op exited without error and the item's timestamp never moved.
    local after
    after=$(get_field "$v")
    after_ts=$(fingerprint "$v")

    echo "$after" | grep -q '"ghcr.io"' \
      || die "wrote to '$v' but ghcr.io is not in the field afterwards"
    if [ -z "$before_ts" ] && [ -z "$after_ts" ]; then
      warn "  could not read a version/timestamp to confirm the write; relying on the value check alone"
    elif [ "$before_ts" = "$after_ts" ]; then
      die "the item in '$v' was not modified (unchanged at $before_ts) -- the write did not land"
    fi

    printf '  now covers: '; echo "$after" | registries_in
    echo "  item updated: $after_ts"
  done

  echo
  green "done. The operator picks this up in both clusters within about a minute,"
  green "once k8s/apps/base/registry-credentials is on master."
  echo
  echo "check with:  $0 verify"
}

cmd_verify() {
  local kc="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"
  [ -f "$kc" ] || die "no staging kubeconfig; run: ./scripts/staging.sh kubeconfig"
  step "secret as it exists in the staging cluster"
  kubectl --kubeconfig "$kc" -n web get secret zot-registry-credentials \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d | registries_in \
    || die "zot-registry-credentials not found -- is the OnePasswordItem CR on master yet?"
}

# Every op call, run one at a time with stderr shown and exit codes printed.
# The normal path suppresses stderr to avoid leaking values into logs, which also
# hides the reason a call fails -- this is the escape hatch for that.
cmd_doctor() {
  # Deliberately does NOT call need_session: whether the session works is one of
  # the things being diagnosed, so it must not be a precondition.
  command -v op >/dev/null || die "the 1Password CLI is not on PATH"
  # And `set -e` is off for the duration: a failing call is the finding here, not
  # a reason to stop. Every step should run so the whole picture is visible.
  set +e
  local v="${1:-Kubernetes}"
  echo "  op version : $(op --version 2>&1)"
  echo "  vault      : $v"
  echo "  item       : $ITEM"
  echo

  echo "[1] op whoami"
  op whoami; echo "    exit=$?"
  echo

  echo "[2] op item get '$ITEM' --vault '$v'  (does the item resolve at all)"
  op item get "$ITEM" --vault "$v" --format json >/dev/null; echo "    exit=$?"
  echo

  echo "[3] the field, addressed unqualified as '$FIELD'"
  op item get "$ITEM" --vault "$v" --fields "$FIELD" --reveal >/dev/null; echo "    exit=$?"
  echo

  echo "[4] the field, addressed with its section"
  local target
  target=$(op item get "$ITEM" --vault "$v" --format json 2>/dev/null | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for f in d.get("fields", []):
    if f.get("label") == ".dockerconfigjson":
        sec = (f.get("section") or {}).get("id")
        print("%s.%s" % (sec, f["label"]) if sec else f["label"]); break')
  echo "    resolved address: ${target:-<none>}"
  if [ -n "$target" ]; then
    op item get "$ITEM" --vault "$v" --fields "$target" --reveal >/dev/null; echo "    exit=$?"
  fi
  echo

  echo "[5] the PAT item"
  op item get "$PAT_ITEM" --vault "$v" --fields password --reveal >/dev/null; echo "    exit=$?"
  echo
  echo "  Values are never printed. Non-zero above is the failing call."
  set -e
}

case "${1:-}" in
  doctor)   shift; cmd_doctor "$@" ;;
  show)     cmd_show ;;
  add-ghcr) cmd_add_ghcr ;;
  verify)   cmd_verify ;;
  *)
    cat >&2 <<EOF
usage: $0 <command> [vault...]

  doctor     run each op call separately, showing exit codes and errors
  show       which registries each vault's copy currently covers
  add-ghcr   add a ghcr.io entry, preserving what is already there
  verify     what the staging cluster actually has

Vaults default to: Kubernetes (the only vault any OnePasswordItem references)
Needs a 1Password session in this shell: eval \$(op signin)
EOF
    exit 1 ;;
esac
