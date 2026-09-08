#!/usr/bin/env bash
# The OVH staging trial: order a VPS-1, put k3s on it, find out if OVH works.
#
#   ./scripts/staging-ovh.sh plan      # what would be ordered, and what it costs
#   ./scripts/staging-ovh.sh up        # order it and install k3s
#   ./scripts/staging-ovh.sh status    # what exists, read from the OVH API
#   ./scripts/staging-ovh.sh ssh
#   ./scripts/staging-ovh.sh kubeconfig
#   ./scripts/staging-ovh.sh destroy   # terminate the service
#
# `up` is two applies, and that is forced rather than chosen:
#
#   1. order the VPS. No SSH key can be attached yet -- the provider refuses
#      public_ssh_key without image_id, and image_id is only listed by
#      /vps/{serviceName}/images/available, which needs the VPS to exist.
#   2. read the image id and the address from the API, write both into tfvars,
#      apply again. That triggers /vps/{name}/rebuild with our key and
#      doNotSendPassword, then uploads and runs the k3s install over SSH.
#
# The address is read from the API because the provider exposes it nowhere --
# not on the resource, not on the data source.
#
# UNLIKE staging.sh THERE IS NO `down`. An OVH VPS is a subscription, not an
# hourly instance: there is nothing to stop and restart, and terminating on a
# committed pricing mode still bills to the end of the term. Use `destroy`, and
# understand that it is a cancellation rather than a spin-down.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME=staging-ovh
TF_DIR="$REPO/terraform/envs/$ENV_NAME"
TFVARS="$TF_DIR/terraform.tfvars"
API="$REPO/scripts/setup/ovh-api.py"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

tf() { terraform -chdir="$TF_DIR" "$@"; }

tfvar() { grep -oP "^$1\s*=\s*\"\K[^\"]*" "$TFVARS" 2>/dev/null | head -1 || true; }

set_var() { # name value
  TFVARS="$TFVARS" VNAME="$1" VVALUE="$2" python3 - <<'PY'
import json, os, re
p, n, v = os.environ["TFVARS"], os.environ["VNAME"], os.environ["VVALUE"]
s = open(p).read()
line = "%s = %s" % (n, json.dumps(v))
if re.search(r"^%s\s*=" % re.escape(n), s, re.M):
    s = re.sub(r"^%s\s*=.*$" % re.escape(n), line, s, count=1, flags=re.M)
else:
    s = s.rstrip("\n") + "\n" + line + "\n"
open(p, "w").write(s)
PY
}

# Credentials come out of tfvars so there is one place they live, and are handed
# to the API helper through the environment rather than the command line, where
# they would be visible in ps output.
api() { # METHOD PATH [BODY]
  OVH_EP="$(tfvar ovh_endpoint)" \
  OVH_AK="$(tfvar ovh_application_key)" \
  OVH_AS="$(tfvar ovh_application_secret)" \
  OVH_CK="$(tfvar ovh_consumer_key)" \
  python3 "$API" "$@"
}

preflight() {
  command -v terraform >/dev/null || die "terraform not on PATH"
  [ -f "$TFVARS" ] || die "missing $TFVARS -- copy terraform.tfvars.example, then run: ./scripts/setup/ovh-credentials.sh write $ENV_NAME"
  for v in ovh_application_key ovh_application_secret ovh_consumer_key; do
    [ -n "$(tfvar "$v")" ] || die "$v is empty -- run: ./scripts/setup/ovh-credentials.sh write $ENV_NAME"
  done
  if [ -z "$(tfvar k3s_token)" ]; then
    step "generating k3s_token"
    set_var k3s_token "$(openssl rand -hex 32)"
  fi
  [ -d "$TF_DIR/.terraform" ] || tf init -input=false >/dev/null
}

service_name() { tf output -raw service_name 2>/dev/null | grep -E '^[a-z0-9.-]+$' || true; }

cmd_plan() {
  preflight
  step "what would be ordered"
  local pc dc os_ mode dur
  pc=$(tfvar vps_plan_code);   pc=${pc:-vps-2027-model1}
  dc=$(tfvar vps_datacenter);  dc=${dc:-US-EAST-VA}
  os_=$(tfvar vps_os);         os_=${os_:-Ubuntu 24.04}
  mode=$(tfvar vps_pricing_mode); mode=${mode:-default}
  dur=$(tfvar vps_duration);   dur=${dur:-P1M}
  printf '  plan          %s\n  datacenter    %s\n  os            %s\n  pricing       %s (%s)\n' \
    "$pc" "$dc" "$os_" "$mode" "$dur"

  # Straight from the public catalog rather than a number written in a comment,
  # so it cannot go stale.
  step "price, from OVH's public catalog"
  PLAN="$pc" MODE="$mode" python3 - <<'PY'
import json, os, urllib.request
url = "https://api.us.ovhcloud.com/1.0/order/catalog/public/vps?ovhSubsidiary=US"
d = json.load(urllib.request.urlopen(url, timeout=60))
plan, mode = os.environ["PLAN"], os.environ["MODE"]
total = 0.0
def price_of(entries, code):
    for e in entries:
        if e.get("planCode") != code:
            continue
        for pr in e.get("pricings", []):
            if pr.get("mode") == mode and "renew" in pr.get("capacities", []):
                return pr["price"] / 1e8, e.get("invoiceName", code)
    return None, None
p, name = price_of(d["plans"], plan)
if p is None:
    print("  plan %s has no %s pricing" % (plan, mode)); raise SystemExit(1)
print("  %-38s $%.2f/mo" % (name, p)); total += p
for addon in ("option-linux", "option-storage-local-2027-model1", "option-auto-backup-2027-1-model1"):
    ap, aname = price_of(d.get("addons", []), addon)
    if ap is not None:
        print("  %-38s $%.2f/mo" % ((aname or addon)[:38], ap)); total += ap
print("  %-38s $%.2f/mo" % ("TOTAL", total))
PY
  echo
  step "terraform plan"
  tf plan -input=false
}

cmd_up() {
  preflight

  local sn; sn=$(service_name)
  if [ -z "$sn" ]; then
    warn "This ORDERS a VPS and charges the payment method on the OVH account."
    warn "It is a subscription: there is no hourly billing and no spin-down."
    cmd_plan >/dev/null 2>&1 || true
    echo
    read -r -p "Type 'order' to place it: " reply
    [ "$reply" = "order" ] || die "aborted"

    step "ordering (OVH delivery can take several minutes)"
    tf apply -input=false -auto-approve
    sn=$(service_name)
    [ -n "$sn" ] || die "the order completed but no service_name came back"
    green "delivered: $sn"
  else
    step "already ordered: $sn"
  fi

  # --- discover what the provider will not tell us ---------------------------
  step "reading the address from /vps/$sn/ips"
  local host
  host=$(api GET "/vps/$sn/ips" | python3 -c '
import sys, json, ipaddress
for ip in json.load(sys.stdin):
    a = ip.split("/")[0]
    try:
        if isinstance(ipaddress.ip_address(a), ipaddress.IPv4Address):
            print(a); break
    except ValueError:
        pass')
  [ -n "$host" ] || die "no IPv4 address on $sn yet -- OVH may still be provisioning; re-run in a minute"
  green "address: $host"
  set_var vps_host "$host"

  step "matching '$(tfvar vps_os)' against the images available to this VPS"
  # The listed ids are opaque, so each one has to be fetched to learn its name.
  local ids want match="" name
  ids=$(api GET "/vps/$sn/images/available" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)))')
  want=$(tfvar vps_os)
  for id in $ids; do
    name=$(api GET "/vps/$sn/images/available/$id" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("name",""))')
    printf '  %-40s %s\n' "$name" "$id"
    if [ "$name" = "$want" ]; then match="$id"; fi
  done
  [ -n "$match" ] || die "no image named exactly '$want' is available on $sn -- pick one of the names listed above and set vps_os"
  set_var vps_image_id "$match"

  step "reinstalling with our SSH key, then installing k3s"
  tf apply -input=false -auto-approve

  echo
  green "OVH staging is up at $host"
  cmd_status
}

cmd_status() {
  preflight
  local sn; sn=$(service_name)
  if [ -z "$sn" ]; then
    printf 'service   : none ordered\n'
    return 0
  fi
  printf 'service   : %s\n' "$sn"
  api GET "/vps/$sn" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in ("state", "offerType", "vcore", "memoryLimit", "displayName", "zone", "model"):
    v = d.get(k)
    if isinstance(v, dict):
        v = v.get("name", v)
    if v is not None:
        print("%-10s: %s" % (k, v))'
  local host; host=$(tfvar vps_host)
  printf 'address   : %s\n' "${host:-<unknown>}"
  [ -n "$host" ] || return 0
  if timeout 5 bash -c "echo > /dev/tcp/$host/22" 2>/dev/null; then
    printf 'ssh (22)  : open\n'
  else
    printf 'ssh (22)  : closed\n'
  fi
  if timeout 5 bash -c "echo > /dev/tcp/$host/6443" 2>/dev/null; then
    printf 'k3s (6443): open\n'
  else
    printf 'k3s (6443): closed (k3s may not be installed yet)\n'
  fi
}

keyfile() {
  local f="$TF_DIR/.ssh_key"
  tf output -raw ssh_private_key > "$f"
  chmod 600 "$f"
  printf '%s' "$f"
}

ssh_to() {
  local host; host=$(tfvar vps_host)
  [ -n "$host" ] || die "no address known -- run: $0 up"
  local key; key=$(keyfile)
  ssh-keygen -R "$host" >/dev/null 2>&1 || true
  ssh -i "$key" -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \
      -o ConnectTimeout=15 "root@$host" "$@"
}

cmd_kubeconfig() {
  preflight
  local host; host=$(tfvar vps_host)
  local out="$REPO/kubeconfig-staging-ovh.yaml" tmp
  tmp=$(mktemp)
  ssh_to cat /etc/rancher/k3s/k3s.yaml > "$tmp" || die "could not read the kubeconfig over SSH"
  grep -q '^apiVersion:' "$tmp" || { rm -f "$tmp"; die "what came back is not a kubeconfig"; }
  sed "s/127.0.0.1/$host/" "$tmp" > "$out"
  rm -f "$tmp"; chmod 600 "$out"
  green "wrote $out"
  echo "export KUBECONFIG=$out"
}

cmd_destroy() {
  preflight
  local sn; sn=$(service_name)
  [ -n "$sn" ] || { green "nothing ordered"; return 0; }
  warn "This TERMINATES the OVH service $sn."
  warn "On a committed pricing mode the commitment still bills to the end of its"
  warn "term -- terminating does not refund it. On 'default' it stops at the end"
  warn "of the current month."
  read -r -p "Type 'terminate' to continue: " reply
  [ "$reply" = "terminate" ] || die "aborted"
  tf destroy -input=false -auto-approve
  set_var vps_host ""
  set_var vps_image_id ""
  green "terminated and tfvars reset"
}

case "${1:-}" in
  plan)       cmd_plan ;;
  up)         cmd_up ;;
  status)     cmd_status ;;
  ssh)        shift; preflight; ssh_to "$@" ;;
  kubeconfig) cmd_kubeconfig ;;
  destroy)    cmd_destroy ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  plan        what would be ordered, priced from OVH's live catalog
  up          order the VPS, install our key, install k3s
  status      what exists, read from the OVH API
  ssh         shell on the box
  kubeconfig  fetch it to kubeconfig-staging-ovh.yaml
  destroy     terminate the service

There is no 'down'. An OVH VPS is a subscription, not an hourly instance.
EOF
    exit 1 ;;
esac
