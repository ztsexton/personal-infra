# Rebuilding staging from scratch

How to destroy the staging VM and bring a new one back with
`https://staging.petfoodfinder.app` serving a real response over a valid
certificate.

Steps 1 and 2 are one-time. After that the cycle is two commands plus step 6,
which is not yet automatic.

> This runbook describes **Hetzner** staging, driven by `scripts/staging.sh`.
> That environment is currently a template — nothing it describes exists. The
> staging cluster that actually runs is the OVH one (`scripts/staging-ovh.sh`,
> `terraform/envs/staging-ovh/`), which syncs the same `k8s/argocd/staging` path
> and so needs the same step 6. Where a command below takes an environment name,
> the live one is `staging-ovh`.

---

## What has to be true for that URL to work

Five things, in order. Four are automatic; one is not yet.

| # | Requirement | Provided by | Automatic |
| - | ----------- | ----------- | --------- |
| 1 | `staging.petfoodfinder.app` resolves to the staging IP | Terraform `dns_records` | yes |
| 2 | Traefik holds that IP as its LoadBalancer | MetalLB pool + Traefik values, pinned to the retained address | yes |
| 3 | A trusted certificate for the host | cert-manager, using the Cloudflare token the bootstrap writes | yes |
| 4 | An Ingress routing the host to the app | `k8s/apps/overlays/staging/ingress/ballroom-competition-web-ingress.yaml` | yes |
| 5 | `ballroom-competition-web` actually running | needs `zot-registry-credentials` to pull from `zot.zachsexton.com` | **no — step 4 below** |

Step 5 is the only reason that URL is currently a 404 rather than a 200.

---

## Step 1 — 1Password Connect credentials (one-time)

Without these the operator never starts, `zot-auth` is never created, and step 4
has nothing to derive a pull secret from.

Requires an interactive 1Password sign-in and membership in a group with the
**manage Secrets Automation** permission. A service account token will not work:
service accounts cannot create Connect servers.

```bash
# in your own terminal -- the op session is an env var and does not survive
# into other shells
eval $(op signin)

./scripts/setup/onepassword-connect.sh check     # must report "signed in"
./scripts/setup/onepassword-connect.sh list      # read-only; shows production's server
./scripts/setup/onepassword-connect.sh create personal-infra-staging Kubernetes,Kubernetes-Staging
```

`check` tests `op whoami`, not `op account list` — the latter exits 0 for an
account that is merely *added*, signed in or not, so it cannot detect a session.
All three must run in the same shell as the `op signin`.

Both vaults on purpose: every `OnePasswordItem` in the repo references
`vaults/Kubernetes/...`, so a server scoped only to the staging vault resolves
none of them.

Creating a server is additive — production's Connect server, its credentials and
its tokens are untouched, and vault access is granted per server.

The script writes both values into `terraform/envs/staging/terraform.tfvars`
(gitignored) and leaves a copy of the credentials file at
`1password-credentials.json.KEEP-ME`.

> **Put that copy in 1Password, then delete it.** A Connect server's credentials
> file cannot be downloaded a second time. Lose it and the only recovery is
> creating a new server.

Verify:

```bash
grep -c '^onepassword_.* = "..*"' terraform/envs/staging/terraform.tfvars   # expect 2
```

## Step 2 — Confirm the address is protected (one-time)

```bash
./scripts/setup/hcloud-primary-ip.sh list
```

`personal-staging-ipv4` must show `auto_delete=false`. That is what keeps the
address across a destroy, which in turn keeps the DNS records and the IP
hardcoded in the staging MetalLB pool and Traefik values valid — and is why
`up` needs no manifest edit.

If it ever shows `auto_delete=true`:

```bash
./scripts/setup/hcloud-primary-ip.sh protect <that-ip>
```

---

## Step 3 — Destroy and recreate

```bash
./scripts/staging.sh down     # ~30s
./scripts/staging.sh up       # ~4 min
```

`down` is a targeted destroy of the server. A plain `terraform destroy` fails on
the primary IP's `prevent_destroy`. The DNS records go with the server and are
recreated by `up` against the same address, so they come back identical.

`up` allocates the address if needed, checks the manifests point at it, builds
the server, runs the bootstrap (k3s → 1Password secrets → Cloudflare token →
Argo CD → root Application), waits for Argo CD to work through sync waves −1..2,
then runs `verify`.

It is safe to re-run. If only the tfvars changed, it re-runs the bootstrap
(~90s) without touching the server.

## Step 4 — Nothing to do

The registry pull secret used to be a manual `kubectl` here. It is now a
`OnePasswordItem` (`k8s/apps/base/registry-credentials`), so the operator creates
it from the vault in every cluster, and a rebuild reproduces it on its own.

If it is missing, the credential is wrong or absent in 1Password rather than in
the cluster:

```bash
./scripts/secrets.sh status              # is it synced, or orphaned?
./scripts/setup/registry-auth.sh show    # which registries the vault value covers
```

It cannot be derived from `zot-auth`: that secret holds an htpasswd line, whose
second field is a bcrypt hash rather than a password.

## Step 5 — Verify

```bash
./scripts/staging.sh verify
```

Expected once steps 1–4 are done:

```text
HOST                                       DNS      CODE   NOTE
staging.zachsexton.com                     ok       200
petfoodfinder-staging.zachsexton.com       ok       200
vigilo-staging.zachsexton.com              ok       200
spotifybutler-staging.zachsexton.com       ok       200
staging.petfoodfinder.app                  ok       200
syllabus-staging.zachsexton.com            ok       200
zot-staging.zachsexton.com                 ok       200   (auth required -- serving)
grafana-staging.zachsexton.com             ok       302
argocd-staging.zachsexton.com              ok       200
```

`verify` deliberately does **not** pass `-k`. A self-signed certificate counts as
a failure, because that is exactly what happens when cert-manager cannot solve
the DNS01 challenge — and it is easy to miss otherwise.

The direct check for the host you care about:

```bash
curl -sI https://staging.petfoodfinder.app | head -1
```

---

## Step 6 — Hand `argocd-secret` to the 1Password operator

Not automatic, and a rebuild is not finished without it. Skip it and Argo CD
comes back with the password from `argocd_admin_password_bcrypt` in the tfvars
rather than the one in 1Password — and then loses its password entirely the
first time the root Application syncs.

Why it cannot simply be declarative: `k8s/argocd/staging/argocd-secret.yaml`
makes the operator own `argocd-secret`, but the bootstrap has already created
that Secret from the Helm values. It has to, because Argo CD must be running
before it can deploy the operator that would otherwise supply the password. So
the operator *adopts* a Secret it did not create, and in doing so stamps the
CR's labels onto it — including Argo CD's own tracking label,
`argocd.argoproj.io/instance: root`. Argo CD's next sync then sees a resource it
believes it owns and cannot find in git, and prunes it:

```text
Sync/3 resource /Secret:argocd/argocd-secret obj->nil
Adding resource result, status: 'Pruned' ... kind=Secret name=argocd-secret
```

Secrets the operator *creates* carry an ownerReference from birth and are treated
as children of their CR instead — which is why the other eight in the cluster
have survived for months. So the fix is to let it create one:

```bash
eval $(op signin)
./scripts/setup/argocd-admin-secret.sh adopt  staging-ovh
./scripts/setup/argocd-admin-secret.sh verify staging-ovh
```

`adopt` is safe to run at any point, including before the prune has happened. It
refuses unless the 1Password item carries every key the live Secret has, backs
the Secret up to `.argocd-backups/` before deleting anything, and fails loudly
with the restore command if the operator does not rebuild it. `verify` is the
proof: it bcrypt-checks the plaintext stored in `Argo CD (staging)` against the
hash the cluster is actually running.

### The first time, on a cluster that has never had this

`create` builds the 1Password item by copying the **live** `argocd-secret`, so
the first bootstrap must already have happened — there is no way to write
`server.secretkey` into the item before a cluster exists to take it from. That
ordering is the one thing here nobody would guess:

```bash
./scripts/setup/argocd-admin-secret.sh create staging-ovh   # after the first `up`
git add -A && git commit && git push                        # Argo CD syncs the CR
./scripts/setup/argocd-admin-secret.sh adopt  staging-ovh
```

Once the item exists in 1Password it survives every later rebuild — including
`server.secretkey`, so sessions stop being re-keyed on every rebuild — and only
`adopt` is needed.

---

## When it does not come up

`verify` names the pod behind each failing host and its last Warning event. The
common ones:

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `ImagePullBackOff` / `zot-registry-credentials` | step 4 not done, or redone after a rebuild | step 4 |
| `ContainerCreating` / `zot-auth not found` | 1Password operator not running | `./scripts/secrets.sh status`, then step 1 |
| every host fails TLS | cert-manager has no Cloudflare token | check `cloudflare_api_token` is set in the tfvars, then `up` |
| certificates stuck `READY=False` | stale ACME challenges from before the token existed | `./scripts/certs.sh unstick` |
| `argocd-staging` returns 502 | the ingress is on port 443 | must be port 80: the bootstrap sets `server.insecure`, so argocd-server speaks plain HTTP |
| Traefik LoadBalancer stuck `<pending>` | MetalLB pool does not match the real address | `./scripts/setup/set-env-ip.sh staging <ip>`, commit, push |
| cannot log into `argocd-staging`; `argocd-secret` missing | the CR synced and Argo CD pruned the adopted Secret | step 6 |
| logging in still wants the old password | the operator has not rebuilt the Secret yet | `argocd-admin-secret.sh verify staging-ovh` |

Useful:

```bash
./scripts/staging.sh status      # address, server, k3s, ingress
./scripts/staging.sh verify      # every configured URL, with real TLS
./scripts/certs.sh status        # certificates and stuck challenges
./scripts/secrets.sh status      # what exists, what is missing, what is orphaned
./scripts/secrets.sh sources     # which vault item each secret comes from
./scripts/staging.sh ssh
```

---

## Automating step 6

The same shape as step 4's automation below: after applying the root
Application, the bootstrap could wait for the `argocd-secret` OnePasswordItem to
report `Ready`, then delete the Helm-created Secret so the operator rebuilds it
as owner, restoring from a backup if it does not come back. Non-fatal, so a slow
sync does not fail the apply.

It is not implemented, because that code would run on every `terraform apply`
that re-runs the bootstrap, and the failure mode of getting it wrong is a
cluster with no admin password.

## Automating step 4

Step 4 is the only thing keeping this from being a genuine two-command rebuild.
It can be closed by having the bootstrap, after applying the root Application,
poll for `zot-auth` for a few minutes and derive the pull secret if it appears —
non-fatal, so a slow or failed sync does not fail the apply.

The alternative is an in-cluster Job in the staging manifests that watches for
`zot-auth`. More GitOps-native, does not slow `up`, more moving parts.

Neither is implemented yet.

## Cost

A `cpx21` is roughly EUR 8/month; an unassigned primary IPv4 is roughly EUR 0.60.
`down` therefore saves over 90% while keeping the address, and the whole point of
keeping it is that `up` stays a single command.
