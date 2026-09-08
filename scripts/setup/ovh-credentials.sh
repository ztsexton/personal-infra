#!/usr/bin/env bash
# OVH API credentials: find them in 1Password, prove they work, hand them to terraform.
#
#   ./scripts/setup/ovh-credentials.sh show
#   ./scripts/setup/ovh-credentials.sh check
#   ./scripts/setup/ovh-credentials.sh write <env>
#
# OVH does not have a single API token. Four values are needed together:
#
#   endpoint            which OVH region the account belongs to. The credentials
#                       are only valid against one of them, and the wrong choice
#                       fails as "invalid signature" rather than anything that
#                       points at the real problem. `check` finds it for you.
#   application_key     identifies the application
#   application_secret  signs each request
#   consumer_key        identifies the user, AND carries the scopes. This is the
#                       one that silently limits you: a consumer key is granted
#                       specific method+path pairs at creation, so a key that
#                       reads /me fine can still be unable to order a VPS, and
#                       terraform only discovers that mid-apply.
#
# `check` therefore probes each path terraform will actually need and reports
# which are permitted, rather than just confirming the credentials authenticate.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT="${OVH_VAULT:-Dev Vault}"
PY="${PY:-python3}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

# `op account list` exits 0 with no session, so it cannot be used as the test.
need_session() {
  command -v op >/dev/null || die "1Password CLI not installed"
  op whoami >/dev/null 2>&1 || die "no 1Password session -- run: eval \$(op signin)"
}

# Named explicitly if you know it, otherwise anything in the vault that looks
# like an OVH credential.
find_item() {
  if [ -n "${OVH_ITEM:-}" ]; then printf '%s' "$OVH_ITEM"; return; fi
  local hits
  hits=$(op item list --vault "$VAULT" --format json 2>/dev/null \
    | "$PY" -c 'import sys,json;print("\n".join(i["title"] for i in json.load(sys.stdin) if "ovh" in i["title"].lower()))')
  [ -n "$hits" ] || die "no item with 'ovh' in its title in vault '$VAULT' -- set OVH_ITEM=<title> or OVH_VAULT=<vault>"
  if [ "$(printf '%s\n' "$hits" | wc -l)" -gt 1 ]; then
    red "more than one candidate in '$VAULT':"
    printf '  %s\n' $hits >&2
    die "pick one with OVH_ITEM=<title>"
  fi
  printf '%s' "$hits"
}

# Field labels and value shapes only. Never the values themselves: this script
# exists to be run while someone is looking at the screen.
cmd_show() {
  need_session
  local item; item=$(find_item)
  step "item '$item' in vault '$VAULT'"
  op item get "$item" --vault "$VAULT" --format json \
    | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
rows = []
for f in d.get("fields", []):
    label = f.get("label") or f.get("id") or "?"
    v = f.get("value")
    if v is None:
        continue
    sec = (f.get("section") or {}).get("label")
    rows.append(((sec + " / " if sec else "") + label, f.get("type", "?"), len(v)))
if not rows:
    print("  (no populated fields)")
for label, typ, n in rows:
    print("  %-38s %-10s %d chars" % (label, typ.lower(), n))
'
}

# Pull the four values out of the item. Matching is on a normalised label so it
# survives "Application Key" / "application_key" / "APPLICATION KEY".
read_creds() { # -> endpoint\napp_key\napp_secret\nconsumer_key  (blank line if absent)
  local item; item=$(find_item)
  op item get "$item" --vault "$VAULT" --format json \
    | "$PY" -c '
import sys, json, re
d = json.load(sys.stdin)
def norm(s): return re.sub(r"[^a-z]", "", (s or "").lower())
vals = {}
for f in d.get("fields", []):
    v = f.get("value")
    if not v:
        continue
    vals[norm(f.get("label") or f.get("id"))] = v
def pick(*names):
    for n in names:
        if n in vals:
            return vals[n]
    return ""
print(pick("endpoint", "region", "apiendpoint"))
print(pick("applicationkey", "appkey", "apikey", "key", "username"))
print(pick("applicationsecret", "appsecret", "secret", "password"))
print(pick("consumerkey", "consumer", "credential"))
'
}

ENDPOINTS="ovh-eu=https://eu.api.ovh.com/1.0 ovh-us=https://api.us.ovhcloud.com/1.0 ovh-ca=https://ca.api.ovh.com/1.0"

# The paths terraform touches to order and manage a VPS. A consumer key can
# authenticate perfectly and still be missing any of these.
PROBES="GET:/me GET:/vps GET:/order/cart POST:/order/cart GET:/me/paymentMean"

cmd_check() {
  need_session
  local creds ep ak as ck
  creds=$(read_creds)
  ep=$(sed -n 1p <<<"$creds")
  ak=$(sed -n 2p <<<"$creds")
  as=$(sed -n 3p <<<"$creds")
  ck=$(sed -n 4p <<<"$creds")

  step "what the item holds"
  printf '  endpoint            %s\n' "${ep:-<absent -- will be detected>}"
  printf '  application_key     %s\n' "$([ -n "$ak" ] && echo "present (${#ak} chars)" || echo '<ABSENT>')"
  printf '  application_secret  %s\n' "$([ -n "$as" ] && echo "present (${#as} chars)" || echo '<ABSENT>')"
  printf '  consumer_key        %s\n' "$([ -n "$ck" ] && echo "present (${#ck} chars)" || echo '<ABSENT>')"

  local missing=""
  [ -n "$ak" ] || missing="$missing application_key"
  [ -n "$as" ] || missing="$missing application_secret"
  [ -n "$ck" ] || missing="$missing consumer_key"
  if [ -n "$missing" ]; then
    echo
    red "missing:$missing"
    red "All three are issued together. Create a new set at whichever applies:"
    red "  https://api.us.ovhcloud.com/createToken/   (OVH US account)"
    red "  https://eu.api.ovh.com/createToken/        (OVH EU account)"
    red "Grant these rights, or ordering will fail mid-apply:"
    red "  GET/POST/PUT/DELETE on  /me/*  /vps/*  /order/*  /services/*"
    exit 1
  fi

  echo
  step "probing endpoints and scopes"
  OVH_AK="$ak" OVH_AS="$as" OVH_CK="$ck" OVH_EP="$ep" OVH_ENDPOINTS="$ENDPOINTS" \
  OVH_PROBES="$PROBES" "$PY" - <<'PY'
import hashlib, json, os, sys, time, urllib.error, urllib.request

ak, as_, ck = os.environ["OVH_AK"], os.environ["OVH_AS"], os.environ["OVH_CK"]
named = os.environ.get("OVH_EP", "").strip()
eps = dict(p.split("=", 1) for p in os.environ["OVH_ENDPOINTS"].split())
probes = [p.split(":", 1) for p in os.environ["OVH_PROBES"].split()]

def call(base, method, path, body=""):
    # OVH signs with its own clock, not ours; a skewed local clock is otherwise
    # indistinguishable from a bad secret.
    try:
        ts = urllib.request.urlopen(base + "/auth/time", timeout=10).read().decode().strip()
    except Exception as e:
        return None, "unreachable (%s)" % e
    url = base + path
    raw = "+".join([as_, ck, method, url, body, ts])
    sig = "$1$" + hashlib.sha1(raw.encode()).hexdigest()
    req = urllib.request.Request(url, method=method,
                                 data=body.encode() if body else None)
    req.add_header("X-Ovh-Application", ak)
    req.add_header("X-Ovh-Consumer", ck)
    req.add_header("X-Ovh-Timestamp", ts)
    req.add_header("X-Ovh-Signature", sig)
    req.add_header("Content-Type", "application/json")
    try:
        return urllib.request.urlopen(req, timeout=20).read().decode(), None
    except urllib.error.HTTPError as e:
        return None, "%d %s" % (e.code, (e.read().decode()[:120] or e.reason))
    except Exception as e:
        return None, str(e)

candidates = [(named, eps[named])] if named in eps else list(eps.items())

# A 403 "not been granted" is the opposite of a credential problem: the request
# was signed correctly and OVH recognised it, the consumer key simply lacks that
# path. Reporting it as "these credentials do not work" sends you off rotating a
# secret that was fine all along, so the two are separated here.
live = None
scoped_out = None
for name, base in candidates:
    out, err = call(base, "GET", "/me")
    if out is not None:
        live = (name, base, json.loads(out))
        break
    if "not been granted" in (err or ""):
        scoped_out = (name, base)
        break
    print("  %-8s %s" % (name, err))

if live is None and scoped_out is not None:
    name, base = scoped_out
    print("\n  endpoint  %s  (%s)" % (name, base))
    print("\nThese credentials are VALID -- correctly signed, right endpoint --")
    print("but the consumer key has not been granted /me.")
    print("\nA consumer key carries a fixed list of method+path pairs chosen when")
    print("it was created, and it cannot be widened afterwards. Create a new one:")
    print("  %s/createToken/" % base.rsplit("/1.0", 1)[0])
    print("\ngranting GET, POST, PUT and DELETE on each of:")
    print("  /me/*  /vps/*  /order/*  /services/*")
    print("\nThen put the new application key, secret and consumer key back in")
    print("1Password and re-run: %s check" % sys.argv[0] if len(sys.argv) else "")
    sys.exit(1)

if live is None:
    print("\nno endpoint accepted these credentials.")
    print("If every one says 'invalid signature', the application_secret or")
    print("consumer_key is wrong or the key was revoked. If they say 'This")
    print("credential is not valid', regenerate the token.")
    sys.exit(1)

name, base, me = live
print("\n  endpoint  %s  (%s)" % (name, base))
print("  account   %s  %s" % (me.get("nichandle", "?"), me.get("country", "")))
print("  state     %s" % me.get("state", "?"))

print("\n  scope probes (403 means the consumer key lacks that right):")
lacking = []
for method, path in probes:
    body = "{}" if method == "POST" else ""
    out, err = call(base, method, path, body)
    if out is not None:
        verdict = "ok"
    elif err.startswith("403"):
        verdict = "FORBIDDEN"
        lacking.append("%s %s" % (method, path))
    elif err.startswith("404"):
        verdict = "ok (404 -- permitted, nothing there)"
    else:
        verdict = err[:60]
    print("    %-4s %-20s %s" % (method, path, verdict))

print()
if lacking:
    print("This key cannot: %s" % ", ".join(lacking))
    print("Terraform will fail partway through ordering. Regenerate the token")
    print("with GET/POST/PUT/DELETE on /me/*, /vps/*, /order/*, /services/*")
    sys.exit(1)
print("credentials work and carry every right terraform needs")
PY
}

cmd_write() {
  local env="${1:-}"
  [ -n "$env" ] || die "usage: $0 write <env>   (e.g. staging-ovh)"
  local tfvars="$REPO/terraform/envs/$env/terraform.tfvars"
  [ -d "$REPO/terraform/envs/$env" ] || die "no such environment: terraform/envs/$env"
  need_session

  local creds ep ak as ck
  creds=$(read_creds)
  ep=$(sed -n 1p <<<"$creds"); ak=$(sed -n 2p <<<"$creds")
  as=$(sed -n 3p <<<"$creds"); ck=$(sed -n 4p <<<"$creds")
  [ -n "$ak" ] && [ -n "$as" ] && [ -n "$ck" ] || die "incomplete credentials -- run: $0 check"
  [ -n "$ep" ] || ep="ovh-us"

  [ -f "$tfvars" ] && cp "$tfvars" "$tfvars.bak"
  touch "$tfvars"; chmod 600 "$tfvars"

  TFVARS="$tfvars" EP="$ep" AK="$ak" AS="$as" CK="$ck" "$PY" - <<'PY'
import json, os, re
p = os.environ["TFVARS"]
s = open(p).read()
for name, val in (("ovh_endpoint", os.environ["EP"]),
                  ("ovh_application_key", os.environ["AK"]),
                  ("ovh_application_secret", os.environ["AS"]),
                  ("ovh_consumer_key", os.environ["CK"])):
    line = "%s = %s" % (name, json.dumps(val))
    if re.search(r"^%s\s*=" % re.escape(name), s, re.M):
        s = re.sub(r"^%s\s*=.*$" % re.escape(name), line, s, count=1, flags=re.M)
    else:
        s = s.rstrip("\n") + "\n" + line + "\n"
open(p, "w").write(s.lstrip("\n"))
PY

  # Read back rather than trusting the exit code.
  step "wrote terraform/envs/$env/terraform.tfvars"
  grep -oE '^ovh_[a-z_]+' "$tfvars" | sed 's/^/  /'
  [ -f "$tfvars.bak" ] && echo "  (previous version kept at terraform.tfvars.bak)"
  green "done -- values not shown. Verify with: $0 check"
}

case "${1:-}" in
  show)  cmd_show ;;
  check) cmd_check ;;
  write) shift; cmd_write "$@" ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  show          field names and sizes in the 1Password item (never values)
  check         which endpoint the credentials belong to, and whether the
                consumer key carries every right terraform needs to order a VPS
  write <env>   write them into terraform/envs/<env>/terraform.tfvars

Vault comes from OVH_VAULT, default "$VAULT".
Item is auto-detected; override with OVH_ITEM=<title>.
EOF
    exit 1 ;;
esac
