#!/usr/bin/env bash
# Argo CD's own health, and reloading it when its config is not actually in force.
#
#   ./scripts/argocd.sh status
#   ./scripts/argocd.sh reload
#   ./scripts/argocd.sh password status|show|reset|forget
#
# Several Argo CD settings live in the argocd-cmd-params-cm ConfigMap and reach
# argocd-server as environment variables declared `optional: true`. If a key is
# absent when the pod is created, the variable is simply never set -- and adding
# the key later changes nothing, because env vars are resolved once at pod
# creation. The setting then sits in git, in the ConfigMap, and not in effect,
# with no error anywhere.
#
# Production ran that way from 2026-03-10: server.insecure: true in the
# ConfigMap, ARGOCD_SERVER_INSECURE absent from the running container, so
# argocd-server served TLS to a Traefik speaking plain HTTP and the ingress
# returned 500 -- while every Argo controller synced normally, which is why it
# went unnoticed for six months.
#
# Comparing timestamps does NOT detect this: the ConfigMap object can predate
# the pod while the key inside it does not. The only reliable check is whether
# the variable is actually set in the running container, which is what `status`
# does.
#
# Clusters built by the current bootstrap pass --insecure as a container
# argument instead, so it cannot drift. This is for production, whose Argo CD
# was installed with kubectl and is not managed by that bootstrap.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$REPO/kubeconfig-staging.yaml}"

# The default is staging, which is the safe one to get wrong. Production is a
# different cluster with a different Argo CD, so name it:
#
#   ./scripts/argocd.sh --env production password status
#
# `--env <name>` resolves to $REPO/kubeconfig-<name>.yaml and beats KUBECONFIG.
if [ "${1:-}" = "--env" ]; then
  [ -n "${2:-}" ] || { echo "error: --env needs an environment name" >&2; exit 1; }
  KUBECONFIG_PATH="$REPO/kubeconfig-$2.yaml"
  shift 2
fi

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
step()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()   { red "error: $*"; exit 1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" -n argocd "$@"; }

# A kubeconfig can outlive its cluster: the Hetzner staging server was destroyed
# and kubeconfig-staging.yaml still points at its address. --request-timeout is
# not enough on its own -- it bounds the HTTP request, not the TCP connect, so a
# dead address took 75 seconds to give up. The wall-clock cap is what makes an
# unreachable cluster fail quickly instead of looking like a hung script.
reachable() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 kubectl --kubeconfig "$KUBECONFIG_PATH" get ns --request-timeout=15s >/dev/null 2>&1
  else
    kubectl --kubeconfig "$KUBECONFIG_PATH" get ns --request-timeout=15s >/dev/null 2>&1
  fi
}

preflight() {
  [ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH
  get one with:  cd terraform/envs/<env> && eval \"\$(terraform output -raw kubeconfig_command)\""
  reachable || die "cannot reach the cluster with $KUBECONFIG_PATH
  the server may be gone -- check with:  ./scripts/staging.sh status"
}

# Which cluster is about to be touched. Printed before anything that writes,
# because the only difference between production and staging at the command
# line is one filename.
cluster_banner() {
  local server
  server=$(kubectl --kubeconfig "$KUBECONFIG_PATH" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  printf '  cluster: %s  (%s)\n' "${server:-unknown}" "$(basename "$KUBECONFIG_PATH")"
}

server_pod() { k get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

# Every params key the deployment expects, and whether it reached the container.
# `|| true` throughout: a missing variable is the finding, not an error.
params_in_force() {
  local pod="$1"
  k get deploy argocd-server -o json 2>/dev/null | "${PY:-python3}" -c '
import json, sys
d = json.load(sys.stdin)
for e in d["spec"]["template"]["spec"]["containers"][0].get("env", []):
    ref = (e.get("valueFrom") or {}).get("configMapKeyRef") or {}
    if ref.get("name") == "argocd-cmd-params-cm":
        print("%s %s" % (e["name"], ref.get("key")))'
}

cmd_status() {
  preflight
  step "pods"
  k get pods --no-headers 2>/dev/null | awk '{printf "  %-50s %-8s %s\n", $1, $2, $3}'

  local pod; pod=$(server_pod)
  [ -n "$pod" ] || { warn "no argocd-server pod"; return 0; }

  echo
  step "ConfigMap settings, and whether the running pod actually has them"
  local envdump drift=0 unset_count=0
  envdump=$(k exec "$pod" -- printenv 2>/dev/null || true)
  while read -r var key; do
    [ -n "$var" ] || continue
    local cmval running
    cmval=$(k get cm argocd-cmd-params-cm -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null || true)
    running=$(printf '%s\n' "$envdump" | grep "^$var=" | cut -d= -f2- || true)
    if [ -z "$cmval" ]; then
      # The chart wires up dozens of optional params. Listing every one nobody
      # has set buries the one or two that matter, so they are counted instead.
      unset_count=$((unset_count + 1))
    elif [ "$cmval" = "$running" ]; then
      printf '  \033[0;32m%-32s ConfigMap=%-8s container=%s  in force\033[0m\n' "$key" "$cmval" "$running"
    else
      printf '  \033[0;31m%-32s ConfigMap=%-8s container=%s  NOT IN FORCE\033[0m\n' "$key" "$cmval" "${running:-<absent>}"
      drift=1
    fi
  done < <(params_in_force "$pod")

  [ "$unset_count" -gt 0 ] && printf '  (%d other params are unset in the ConfigMap and so use their defaults)\n' "$unset_count"

  if k get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q -- '--insecure'; then
    echo
    green "  --insecure is also a container argument, so it cannot drift"
  elif [ "$drift" = "1" ]; then
    echo
    red "  the running pod was created before those keys existed."
    red "  they take effect on restart:  $0 reload"
  fi
}

cmd_reload() {
  preflight
  local pod; pod=$(server_pod)
  step "before"
  printf '  %s  started %s\n' "$pod" "$(k get pod "$pod" -o jsonpath='{.status.startTime}' 2>/dev/null)"

  warn "Restarting argocd-server. The UI and API drop for a few seconds."
  warn "Running Applications are NOT affected: syncing is the application"
  warn "controller's job, which is a different deployment and is untouched."
  read -r -p "Type 'reload' to continue: " reply
  [ "$reply" = "reload" ] || die "aborted"

  k rollout restart deploy argocd-server >/dev/null
  k rollout status deploy argocd-server --timeout=180s 2>&1 | tail -1

  echo
  step "after"
  local newpod; newpod=$(server_pod)
  printf '  %s  started %s\n' "$newpod" "$(k get pod "$newpod" -o jsonpath='{.status.startTime}' 2>/dev/null)"
  echo
  cmd_status
}

# Sync operations that will never finish.
#
# Argo CD syncs with PruneLast=true, so deletions happen only after every other
# resource reports healthy. If one of those resources is unhealthy BECAUSE of a
# change waiting in the same sync, the two block each other and the operation
# sits in Running indefinitely -- there is no timeout and no error.
#
# Production hit exactly that: Zot was removed from git and needed pruning, the
# Argo CD ingress was unhealthy (502) and needed the fix that was queued behind
# the prune, and the sync ran for twenty hours. Terminating the operation lets
# auto-sync start a fresh one against the current revision.
cmd_unstick() {
  preflight
  local stuck
  stuck=$(k get applications -o json 2>/dev/null | "${PY:-python3}" -c '
import sys, json, datetime as dt
now = dt.datetime.now(dt.timezone.utc)
for a in json.load(sys.stdin).get("items", []):
    op = (a.get("status") or {}).get("operationState") or {}
    if op.get("phase") != "Running":
        continue
    started = op.get("startedAt")
    age = ""
    if started:
        d = now - dt.datetime.fromisoformat(started.replace("Z", "+00:00"))
        # Under ten minutes it is probably just working.
        if d.total_seconds() < 600:
            continue
        age = "%dh%dm" % (d.total_seconds() // 3600, (d.total_seconds() % 3600) // 60)
    print("%s|%s|%s" % (a["metadata"]["name"], age, (op.get("message") or "")[:70]))')

  if [ -z "$stuck" ]; then
    green "no sync has been running long enough to be considered stuck"
    return 0
  fi

  step "sync operations running for over ten minutes"
  while IFS='|' read -r app age msg; do
    printf '  %-22s running %s
    %s
' "$app" "$age" "$msg"
  done <<<"$stuck"

  echo
  warn "Terminating these lets auto-sync start again from the current revision."
  warn "Nothing is deleted and no manifest is applied by this -- it only ends the"
  warn "stalled attempt."
  read -r -p "Type 'unstick' to continue: " reply
  [ "$reply" = "unstick" ] || die "aborted"

  while IFS='|' read -r app age msg; do
    echo "terminating $app"
    k patch application "$app" --type merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null
  done <<<"$stuck"

  echo
  green "terminated. Argo CD will re-sync within its refresh interval."
}

# Ask Argo CD to try again.
#
# Auto-sync gives up after a handful of failures and reports
# "one or more synchronization tasks completed unsuccessfully (retried 5
# times)". It does not try again on its own, so once the underlying cause is
# fixed -- a corrected image, a secret that now exists -- nothing happens until
# a sync is requested. Pushing an empty commit works too; this avoids polluting
# history to nudge a controller.
cmd_sync() {
  preflight
  local app="${1:-}"
  [ -n "$app" ] || die "usage: $0 sync <application>"
  k get application "$app" >/dev/null 2>&1 || die "no Application named '$app'"

  step "before"
  k get application "$app" -o jsonpath='  sync={.status.sync.status} phase={.status.operationState.phase}{"\n"}' 2>/dev/null

  # Setting .operation is exactly what the UI's Sync button does.
  k patch application "$app" --type merge -p \
    '{"operation":{"initiatedBy":{"username":"argocd.sh"},"sync":{"revision":"HEAD"},"retry":{"limit":2}}}' >/dev/null

  green "sync requested"
  echo
  echo "Watch it with:  kubectl -n argocd get application $app -w"
}

# --- The admin password -------------------------------------------------------
#
# Argo CD keeps only a bcrypt hash, in argocd-secret under admin.password, so a
# forgotten password cannot be read back out of it.
#
# What CAN be read back is argocd-initial-admin-secret: both the Helm chart and
# the plain install manifests write the generated password there in cleartext,
# and it sits there until something deletes it. Clusters built by the Terraform
# bootstrap delete it at the end of the install (bootstrap-cluster.sh.tmpl);
# production was installed with kubectl and never ran that step, which is why
# production's password is still recoverable and staging's is not.
#
# That secret holds the ORIGINAL password. If it has been changed since, the
# value is stale and looks exactly as plausible as a live one. Timestamps do not
# settle it -- admin.passwordMtime moves for reasons other than a new password.
# The only honest check is to bcrypt the initial value against the live hash,
# which is what `status` and `show` do before saying anything.
PASSWORD_BACKUP_DIR="${PASSWORD_BACKUP_DIR:-$REPO/.argocd-backups}"

#
# Each returns empty rather than failing when the secret is not there. An absent
# argocd-initial-admin-secret is the normal state of a bootstrap-built cluster
# and the single most important thing `status` has to report, so it must not be
# able to kill the script: under `set -o pipefail` a `get` that finds nothing
# fails the whole pipeline, and `set -e` would end the run with no output at all.
live_hash()        { k get secret argocd-secret -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null || true; }
live_mtime()       { k get secret argocd-secret -o jsonpath='{.data.admin\.passwordMtime}' 2>/dev/null | base64 -d 2>/dev/null || true; }
initial_password() { k get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true; }

have_py_bcrypt() { "${PY:-python3}" -c 'import bcrypt' >/dev/null 2>&1; }

# 0 = matches, 1 = does not, 2 = cannot tell (no bcrypt implementation here).
bcrypt_check() {
  local pass="$1" hash="$2"
  if have_py_bcrypt; then
    "${PY:-python3}" -c 'import bcrypt, sys
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

# Argo CD's Go bcrypt accepts $2y$, but Argo CD's own documented recipe
# normalises to $2a$ and every hash in these clusters is $2a$. Keep them uniform
# so a hash never has to be explained.
bcrypt_hash() {
  local pass="$1" h
  if command -v htpasswd >/dev/null 2>&1; then
    h=$(htpasswd -nbBC 10 admin "$pass" | cut -d: -f2)
  elif have_py_bcrypt; then
    h=$("${PY:-python3}" -c 'import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' "$pass")
  else
    die "no way to bcrypt here -- install apache2-utils (htpasswd) or python3 bcrypt"
  fi
  printf '%s\n' "$h" | sed 's/^\$2y\$/\$2a\$/'
}

new_password() {
  "${PY:-python3}" -c 'import secrets, string
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))'
}

# Who writes argocd-secret, which decides where a password change has to be made
# to stick. Three answers, and a kubectl patch is only the right move for one:
#
#   onepassword  a OnePasswordItem owns the Secret. A patch here is reverted on
#                the operator's next sync; the password lives in 1Password now.
#   helm         rendered from argocd_admin_password_bcrypt by the Terraform
#                bootstrap, so a patch survives only until the next apply that
#                re-runs it.
#   kubectl      nothing re-applies it (production), so a patch is the source of
#                truth.
password_owner() {
  local owner
  owner=$(k get secret argocd-secret -o json 2>/dev/null | "${PY:-python3}" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in (d["metadata"].get("ownerReferences") or []):
    if o.get("kind") == "OnePasswordItem":
        print("onepassword"); sys.exit(0)' || true)
  if [ -n "$owner" ]; then
    echo "$owner"
  elif k get deploy argocd-server -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'helm.sh/chart\|app.kubernetes.io/managed-by":"Helm'; then
    echo helm
  else
    echo kubectl
  fi
}

cmd_password_status() {
  preflight
  step "admin password"
  cluster_banner

  local hash mtime init
  hash=$(live_hash); mtime=$(live_mtime); init=$(initial_password)

  [ -n "$hash" ] || die "argocd-secret has no admin.password -- local admin login may be disabled"

  # Shape only. The value is only ever printed by `show`, and only on request.
  printf '  stored hash:      %s... (%d chars, bcrypt)\n' "${hash:0:7}" "${#hash}"
  printf '  last changed:     %s\n' "${mtime:-unknown}"
  printf '  written by:       %s\n' "$(password_owner)"

  local enabled
  enabled=$(k get cm argocd-cm -o jsonpath='{.data.admin\.enabled}' 2>/dev/null || true)
  if [ "$enabled" = "false" ]; then
    warn "  local admin login is DISABLED in argocd-cm; the password will not log you in"
  else
    printf '  local admin login: enabled\n'
  fi

  echo
  if [ -z "$init" ]; then
    red "  argocd-initial-admin-secret: absent"
    red "  Nothing on this cluster holds the password in cleartext, so it cannot be"
    red "  read back. Set a new one:  $0 --env <env> password reset"
    return 0
  fi

  printf '  argocd-initial-admin-secret: present (%d chars)\n' "${#init}"
  local rc=0
  bcrypt_check "$init" "$hash" || rc=$?
  case "$rc" in
    0) green "  and it still matches the stored hash -- it IS the current password."
       green "  read it with:  $0 --env <env> password show" ;;
    1) red   "  but it does NOT match the stored hash: the password was changed after"
       red   "  install, so this value is stale. Set a new one:  $0 --env <env> password reset" ;;
    *) warn  "  could not verify it: no bcrypt available (apache2-utils or python3 bcrypt)" ;;
  esac
}

cmd_password_show() {
  preflight
  local hash init rc=0
  hash=$(live_hash); init=$(initial_password)

  [ -n "$init" ] || die "no argocd-initial-admin-secret on this cluster; the password cannot be read back.
  Set a new one:  $0 --env <env> password reset"

  bcrypt_check "$init" "$hash" || rc=$?
  [ "$rc" != "1" ] || die "argocd-initial-admin-secret does not match the stored hash -- it is the
  original password and the password has been changed since. Set a new one:
  $0 --env <env> password reset"
  if [ "$rc" = "2" ]; then
    warn "could not verify this against the stored hash (no bcrypt available)"
  fi

  step "current admin password"
  cluster_banner
  printf '  username: admin\n'
  printf '  password: %s\n' "$init"
  echo
  warn "This is a standing cleartext copy of a live credential in the cluster."
  warn "Put it in 1Password, then remove it:  $0 --env <env> password forget"
}

cmd_password_reset() {
  preflight
  step "resetting the Argo CD admin password"
  cluster_banner

  local owner; owner=$(password_owner)
  if [ "$owner" = "onepassword" ]; then
    die "argocd-secret is owned by a OnePasswordItem on this cluster, so a patch here
  would be reverted on the operator's next sync. 1Password is the source of
  truth now -- rotate it there instead:
    ./scripts/setup/argocd-admin-secret.sh rotate <env>"
  fi
  if [ "$owner" = "helm" ]; then
    warn "This Argo CD is Helm-managed, so argocd-secret is rendered from"
    warn "argocd_admin_password_bcrypt in that environment's tfvars. A patch here"
    warn "holds until the next apply that re-runs the bootstrap, which will put the"
    warn "Terraform value back. To make it permanent, set the new hash there too --"
    warn "this prints it."
  fi

  [ -n "$(live_hash)" ] || die "argocd-secret has no admin.password to replace"

  warn "The current password stops working immediately and every existing session"
  warn "is invalidated. Argo CD's own syncing is unaffected."
  read -r -p "Type 'reset' to continue: " reply
  [ "$reply" = "reset" ] || die "aborted"

  mkdir -p "$PASSWORD_BACKUP_DIR"; chmod 700 "$PASSWORD_BACKUP_DIR"
  local backup="$PASSWORD_BACKUP_DIR/argocd-secret-$(basename "$KUBECONFIG_PATH" .yaml)-$(date -u +%Y%m%dT%H%M%SZ).yaml"
  ( umask 077; k get secret argocd-secret -o yaml >"$backup" )
  green "backed up argocd-secret to $backup"

  local pass hash now
  pass=$(new_password)
  hash=$(bcrypt_hash "$pass")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Both keys, in one patch. Argo CD rejects tokens issued before
  # admin.passwordMtime, so leaving the mtime behind leaves old sessions live.
  k patch secret argocd-secret -p "$("${PY:-python3}" -c 'import json, sys
print(json.dumps({"stringData": {"admin.password": sys.argv[1], "admin.passwordMtime": sys.argv[2]}}))' "$hash" "$now")" >/dev/null

  # Read it back and prove the new password works against what actually landed,
  # rather than trusting the patch exit code.
  local stored rc=0
  stored=$(live_hash)
  bcrypt_check "$pass" "$stored" || rc=$?
  case "$rc" in
    0) green "verified: the new password matches the hash now stored in the cluster" ;;
    1) die   "the stored hash does not match the new password. Restore with:
  kubectl --kubeconfig $KUBECONFIG_PATH apply -f $backup" ;;
    *) warn  "patched, but could not verify it (no bcrypt available)" ;;
  esac

  echo
  step "new credentials"
  printf '  username: admin\n'
  printf '  password: %s\n' "$pass"
  echo
  warn "Store this in 1Password now -- it is not written anywhere else."
  if [ "$owner" = "helm" ]; then
    echo
    printf '  argocd_admin_password_bcrypt = "%s"\n' "$hash"
    warn "Put that in the environment's terraform.tfvars so a rebuild agrees with it."
  fi
}

cmd_password_forget() {
  preflight
  step "deleting argocd-initial-admin-secret"
  cluster_banner

  [ -n "$(initial_password)" ] || { green "already gone -- nothing to do"; return 0; }

  warn "This is the only cleartext copy of the install-time password. If it is"
  warn "still the current password and it is not in 1Password, deleting it means"
  warn "the only way back in is 'password reset'."
  read -r -p "Type 'forget' to continue: " reply
  [ "$reply" = "forget" ] || die "aborted"

  k delete secret argocd-initial-admin-secret >/dev/null
  if [ -z "$(initial_password)" ]; then
    green "gone. This is the state a bootstrap-built cluster is left in."
  else
    die "the secret is still present after the delete"
  fi
}

cmd_password() {
  case "${1:-}" in
    status) cmd_password_status ;;
    show)   cmd_password_show ;;
    reset)  cmd_password_reset ;;
    forget) cmd_password_forget ;;
    *)
      cat >&2 <<EOF
usage: $0 [--env <name>] password <command>

  status   where the password stands: is a cleartext copy still in the cluster,
           and is it still the current one (read-only, prints no secret)
  show     print the current password, if the cluster still holds a cleartext
           copy that matches the stored hash
  reset    back up argocd-secret, set a new random password, verify it landed
  forget   delete the cleartext copy once it is saved in 1Password
EOF
      exit 1 ;;
  esac
}

case "${1:-}" in
  status) cmd_status ;;
  sync)   shift; cmd_sync "$@" ;;
  unstick) cmd_unstick ;;
  reload) cmd_reload ;;
  password) shift; cmd_password "$@" ;;
  *)
    cat >&2 <<EOF
usage: $0 [--env <name>] <command>

  status    pods, and which ConfigMap settings are actually in force
  reload    restart argocd-server so those settings take effect
  sync      ask Argo CD to retry an Application that gave up
  unstick   terminate a sync that has been running for hours
  password  recover or reset the admin password ($0 password for details)

Cluster comes from --env <name> (-> $REPO/kubeconfig-<name>.yaml), else
KUBECONFIG, else $REPO/kubeconfig-staging.yaml
EOF
    exit 1 ;;
esac
