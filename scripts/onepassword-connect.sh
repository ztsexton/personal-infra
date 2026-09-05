#!/usr/bin/env bash
# Put 1Password Connect credentials into an environment's terraform.tfvars.
#
#   ./scripts/onepassword-connect.sh list
#   ./scripts/onepassword-connect.sh check
#   ./scripts/onepassword-connect.sh create [server-name] [vault]
#   ./scripts/onepassword-connect.sh import <credentials.json> <token>
#
# `create` makes a NEW Connect server and token and writes both into the tfvars.
# `import` takes a credentials file and token you already have -- use this if the
# pair is already saved in 1Password, since **the credentials file cannot be
# re-downloaded** once the Connect server has been created.
#
# Creating a Connect server needs an interactive 1Password sign-in and membership
# in a group with the "manage Secrets Automation" permission. A service account
# token is not sufficient: service accounts cannot create Connect servers.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-staging}"
TFVARS="$REPO/terraform/envs/$ENVIRONMENT/terraform.tfvars"
export PATH="$HOME/bin:$PATH"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

need_op() {
  command -v op >/dev/null || die "the 1Password CLI is not on PATH (installed at ~/bin/op)"
}

cmd_check() {
  need_op
  echo "op version : $(op --version)"
  echo "tfvars     : $TFVARS"
  echo
  if op account list 2>/dev/null | grep -q .; then
    green "signed in:"
    op account list
  else
    warn "not signed in. Either:"
    warn "  - turn on the desktop app integration, or"
    warn "  - op account add --address <team>.1password.com --email <you>"
    warn '    then: eval $(op signin)' 
    return 1
  fi
}

# HCL interpolates \${...} even inside heredocs, so any literal \${ in the value
# has to be escaped or Terraform will try to evaluate it.
write_var() { # name value
  TFVARS="$TFVARS" VNAME="$1" VVALUE="$2" python3 - <<'PY'
import json, os, re
p, n, v = os.environ["TFVARS"], os.environ["VNAME"], os.environ["VVALUE"]
v = v.replace("${", "$${")
s = open(p).read()
line = "%s = %s" % (n, json.dumps(v))
if re.search(r"^%s\s*=" % re.escape(n), s, re.M):
    s = re.sub(r"^%s\s*=.*$" % re.escape(n), line, s, count=1, flags=re.M)
else:
    s = s.rstrip("\n") + "\n" + line + "\n"
open(p, "w").write(s)
PY
}

validate_credentials() { # file
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("not valid JSON: %s" % e)
missing = [k for k in ("verifier", "encCredentials", "uniqueKey") if k not in d]
if missing:
    sys.exit("does not look like 1password-credentials.json (missing %s)" % ", ".join(missing))
print("credentials file looks valid")
PY
}

cmd_list() {
  need_op
  step "Connect servers on this account"
  op connect server list 2>&1
  echo
  echo "Servers are independent: creating one does not touch another's"
  echo "credentials or tokens, and vault access is granted per server"
  echo "(revoking is a separate 'op connect vault revoke')."
}

cmd_create() {
  need_op
  cmd_check >/dev/null || die "sign in first: ./scripts/onepassword-connect.sh check"

  # Show what already exists, so it is obvious this is additive and that
  # production's Connect server is left alone.
  step "Connect servers that already exist (these are not modified)"
  op connect server list 2>&1 | sed 's/^/  /'
  echo

  local server="${1:-personal-infra-$ENVIRONMENT}"
  # Comma-separated. The repo's OnePasswordItem CRs all reference
  # vaults/Kubernetes/..., so a server scoped only to a staging vault resolves
  # none of them.
  local vaults="${2:-Kubernetes,Kubernetes-Staging}"
  local token_name="$server-token"
  local workdir
  workdir=$(mktemp -d)

  step "creating Connect server '$server' with access to: $vaults"
  warn "The credentials file cannot be downloaded again. It is saved into the"
  warn "gitignored tfvars below -- also store it in 1Password."

  ( cd "$workdir" && op connect server create "$server" --vaults "$vaults" ) \
    || die "could not create the Connect server (needs 'manage Secrets Automation')"

  local credfile="$workdir/1password-credentials.json"
  [ -f "$credfile" ] || die "op did not produce 1password-credentials.json"
  validate_credentials "$credfile"

  step "creating a read-only Connect token"
  # The operator only ever reads, so the token is scoped read-only per vault
  # (",r"). If that form is rejected, fall back to inheriting the server's
  # permissions rather than failing the whole run.
  local vaultargs=() v
  IFS=',' read -ra _vs <<<"$vaults"
  for v in "${_vs[@]}"; do vaultargs+=(--vaults "$v,r"); done

  local token
  token=$(op connect token create "$token_name" --server "$server" "${vaultargs[@]}" 2>/dev/null) || token=""
  if [ -z "$token" ]; then
    warn "read-only scoping was rejected; issuing a token with the server's permissions"
    token=$(op connect token create "$token_name" --server "$server") \
      || die "could not create the Connect token"
  fi
  [ -n "$token" ] || die "the token came back empty"

  write_var onepassword_credentials_json "$(cat "$credfile")"
  write_var onepassword_connect_token "$token"

  cp "$credfile" "$REPO/1password-credentials.json.KEEP-ME"
  chmod 600 "$REPO/1password-credentials.json.KEEP-ME"
  rm -rf "$workdir"

  echo
  green "wrote both values into $TFVARS"
  warn  "a copy of the credentials file is at 1password-credentials.json.KEEP-ME"
  warn  "-- put it in 1Password, then delete it. It cannot be regenerated."
  echo
  echo "next:  ./scripts/${ENVIRONMENT}.sh up      # re-runs only the bootstrap"
}

cmd_import() {
  local credfile="${1:-}" token="${2:-}"
  [ -f "$credfile" ] || die "usage: $0 import <credentials.json> <token>"
  [ -n "$token" ]    || die "usage: $0 import <credentials.json> <token>"
  validate_credentials "$credfile"

  write_var onepassword_credentials_json "$(cat "$credfile")"
  write_var onepassword_connect_token "$token"
  green "wrote both values into $TFVARS"
  echo "next:  ./scripts/${ENVIRONMENT}.sh up"
}

case "${1:-}" in
  list)   cmd_list ;;
  check)  cmd_check ;;
  create) shift; cmd_create "$@" ;;
  import) shift; cmd_import "$@" ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  list                               existing Connect servers (read-only)
  check                              is op installed and signed in
  create [server-name] [vaults]      new Connect server + token -> tfvars
                                     vaults is comma-separated;
                                     default: Kubernetes,Kubernetes-Staging
  import <credentials.json> <token>  use a pair you already have

Environment: $ENVIRONMENT  (override with ENVIRONMENT=sandbox)
EOF
    exit 1 ;;
esac
