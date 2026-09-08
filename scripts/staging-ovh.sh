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

tfvar() { python3 "$REPO/scripts/lib/tfvars.py" get "$TFVARS" "$1" 2>/dev/null || true; }

set_var() { # name value
  python3 "$REPO/scripts/lib/tfvars.py" set "$TFVARS" "$1" "$2"
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
  inherit_shared_vars

  if [ -z "$(tfvar k3s_token)" ]; then
    step "generating k3s_token"
    set_var k3s_token "$(openssl rand -hex 32)"
  fi

  if [ -z "$(tfvar argocd_admin_password_bcrypt)" ]; then
    command -v htpasswd >/dev/null \
      || die "htpasswd not found (apt install apache2-utils); needed to hash the Argo CD password"
    local pw hash
    pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
    hash=$(htpasswd -nbBC 10 admin "$pw" | cut -d: -f2)
    set_var argocd_admin_password_bcrypt "$hash"
    step "generated an Argo CD admin password"
    warn "Argo CD login:  admin / $pw"
    warn "Shown once. Only recoverable by regenerating the hash."
  fi

  # Without these the bootstrap skips 1Password entirely, which leaves every
  # OnePasswordItem-backed secret missing -- including the Cloudflare token
  # cert-manager needs, so nothing ever gets a certificate.
  for v in onepassword_connect_token onepassword_credentials_json; do
    if [ -z "$(tfvar "$v")" ]; then
      warn "$v is empty: the bootstrap will skip 1Password, so cert-manager will"
      warn "  have no Cloudflare token and no certificate will ever be issued."
      warn "  Copy it from terraform/envs/staging/terraform.tfvars."
      break
    fi
  done
  [ -d "$TF_DIR/.terraform" ] || tf init -input=false >/dev/null
}

# Cloudflare and 1Password are the same credentials whichever provider hosts
# staging, so they are copied from the Hetzner env rather than pasted in twice.
# Copied only when absent here, so a deliberate override is never clobbered.
inherit_shared_vars() {
  local src="$REPO/terraform/envs/staging/terraform.tfvars"
  [ -f "$src" ] || return 0
  local copied=() val
  for v in cloudflare_api_token cloudflare_zone_id_zachsexton \
           cloudflare_zone_id_petfoodfinder cloudflare_zone_id_vigilo \
           onepassword_connect_token onepassword_credentials_json; do
    [ -z "$(tfvar "$v")" ] || continue
    val=$(python3 "$REPO/scripts/lib/tfvars.py" get "$src" "$v" 2>/dev/null) || continue
    [ -n "$val" ] || continue
    python3 "$REPO/scripts/lib/tfvars.py" set "$TFVARS" "$v" "$val"
    copied+=("$v")
  done
  if [ "${#copied[@]}" -gt 0 ]; then
    step "inherited from staging: ${copied[*]}"
  fi
}

service_name() { tf output -raw service_name 2>/dev/null | grep -E '^[a-z0-9.-]+$' || true; }

# What the order will actually be, and what it costs. Read from OVH's public
# catalog on every run rather than written down here, so it cannot go stale when
# OVH reprices -- which they did in October 2026.
show_order() {
  local pc dc os_ mode dur
  pc=$(tfvar vps_plan_code);      pc=${pc:-vps-2027-model1}
  dc=$(tfvar vps_datacenter);     dc=${dc:-US-EAST-VA}
  os_=$(tfvar vps_os);            os_=${os_:-Ubuntu 24.04}
  mode=$(tfvar vps_pricing_mode); mode=${mode:-default}
  dur=$(tfvar vps_duration);      dur=${dur:-P1M}

  step "what would be ordered"
  printf '  plan          %s\n  datacenter    %s\n  os            %s\n  pricing       %s (%s)\n' \
    "$pc" "$dc" "$os_" "$mode" "$dur"

  step "price, from OVH's public catalog"
  PLAN="$pc" MODE="$mode" DUR="$dur" python3 - <<'PYEOF'
import json, os, urllib.request
url = "https://api.us.ovhcloud.com/1.0/order/catalog/public/vps?ovhSubsidiary=US"
d = json.load(urllib.request.urlopen(url, timeout=60))
plan, mode, dur = os.environ["PLAN"], os.environ["MODE"], os.environ["DUR"]
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
    print("  plan %s has no %s pricing" % (plan, mode))
    raise SystemExit(1)
print("  %-38s $%7.2f" % (name, p))
total += p
for addon in ("option-linux", "option-storage-local-2027-model1",
              "option-auto-backup-2027-1-model1"):
    ap, aname = price_of(d.get("addons", []), addon)
    if ap is not None:
        print("  %-38s $%7.2f" % ((aname or addon)[:38], ap))
        total += ap
print("  %-38s %s" % ("", "-" * 8))
per = {"P1M": "month", "P1Y": "year", "P6M": "6 months"}.get(dur, dur)
print("  %-38s $%7.2f  per %s" % ("TOTAL", total, per))
if mode == "default":
    print()
    print("  Month to month -- cancellable at the end of any month.")
    print("  A 12-month commitment would be cheaper but can only be exited")
    print("  early by paying out the remainder.")
else:
    print()
    print("  COMMITTED. Cancelling early means paying out the rest of the term.")
PYEOF
}

cmd_plan() {
  preflight
  show_order
  echo
  step "terraform plan"
  tf plan -input=false
}

cmd_up() {
  preflight

  local sn; sn=$(service_name)
  if [ -z "$sn" ]; then
    echo
    show_order
    echo
    warn "This ORDERS the above and charges the payment method on the OVH account."
    warn "It is a subscription: there is no hourly billing and no spin-down."
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
  echo
  warn "The cluster is running, but nothing is routed to it yet: the staging"
  warn "manifests still hardcode the Hetzner address, so Traefik's LoadBalancer"
  warn "stays pending and DNS still points elsewhere."
  echo
  echo "To make this the live staging:  $0 promote"
}

# Take the staging hostnames over from whatever was serving them.
#
# Separate from `up` on purpose. `up` builds a cluster and touches nothing
# shared; `promote` rewrites manifests on master and repoints DNS, which takes
# staging away from the Hetzner box. Only one environment can hold these records
# -- they are the same Cloudflare resources terraform/envs/staging manages.
cmd_promote() {
  preflight
  local host; host=$(tfvar vps_host)
  [ -n "$host" ] || die "no address known -- run: $0 up"

  local hetzner_up=""
  if terraform -chdir="$REPO/terraform/envs/staging" state list 2>/dev/null \
       | grep -qx 'module.env.hcloud_server.this'; then
    hetzner_up=1
  fi

  step "what promote does"
  echo "  1. point k8s/argocd/staging/traefik.yaml and the MetalLB pool at $host"
  echo "  2. commit and push that to master (Argo CD reads from GitHub)"
  echo "  3. move the 8 staging DNS records onto $host"
  echo "  4. verify every host serves"
  echo
  if [ -n "$hetzner_up" ]; then
    warn "The Hetzner staging server is STILL RUNNING. After this it keeps"
    warn "running but serves nothing, and its terraform state will describe DNS"
    warn "records that no longer point at it. Spin it down first:"
    warn "  ./scripts/staging.sh down"
    echo
  fi
  read -r -p "Type 'promote' to continue: " reply
  [ "$reply" = "promote" ] || die "aborted"

  step "pointing the staging manifests at $host"
  "$REPO/scripts/setup/set-env-ip.sh" staging "$host"
  local branch; branch=$(git -C "$REPO" branch --show-current)
  git -C "$REPO" add k8s
  git -C "$REPO" commit -q -m "Point staging manifests at $host (OVH)" || true
  if [ "$branch" = "master" ]; then
    git -C "$REPO" push -q || warn "could not push -- Argo CD will not see this until you do"
  else
    warn "on branch '$branch'; Argo CD tracks master, so this takes effect on merge"
  fi

  step "moving DNS"
  set_var manage_dns "true"
  tf apply -input=false -auto-approve

  echo
  step "waiting for Argo CD to converge, then checking every URL"
  cmd_kubeconfig >/dev/null 2>&1 || true
  local i=0
  until [ $i -ge 18 ]; do
    kubectl --kubeconfig "$REPO/kubeconfig-staging-ovh.yaml" -n argocd get applications \
      -o json 2>/dev/null \
      | jq -e '[.items[] | select(.status.sync.status != "Synced")] | length == 0' >/dev/null 2>&1 && break
    i=$((i+1)); sleep 10
  done
  cmd_verify || true
}

cmd_verify() {
  local host; host=$(tfvar vps_host)
  [ -n "$host" ] || die "no address known -- run: $0 up"
  "$REPO/scripts/lib/verify-env.sh" "$host" "$REPO/kubeconfig-staging-ovh.yaml"
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
  promote)    cmd_promote ;;
  verify)     cmd_verify ;;
  status)     cmd_status ;;
  ssh)        shift; preflight; ssh_to "$@" ;;
  kubeconfig) cmd_kubeconfig ;;
  destroy)    cmd_destroy ;;
  *)
    cat >&2 <<EOF
usage: $0 <command>

  plan        what would be ordered, priced from OVH's live catalog
  up          order the VPS, install our key, install k3s, bootstrap Argo CD
  promote     take the staging hostnames and DNS over from Hetzner
  verify      every configured URL, with real TLS validation
  status      what exists, read from the OVH API
  ssh         shell on the box
  kubeconfig  fetch it to kubeconfig-staging-ovh.yaml
  destroy     terminate the service

There is no 'down'. An OVH VPS is a subscription, not an hourly instance.
EOF
    exit 1 ;;
esac
