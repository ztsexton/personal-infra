# Rebuilding staging from scratch

How to destroy the staging VM and bring a new one back with
`https://staging.petfoodfinder.app` serving a real response over a valid
certificate.

Steps 1 and 2 are one-time. After that the whole cycle is two commands.

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

./scripts/onepassword-connect.sh check     # must report "signed in"
./scripts/onepassword-connect.sh list      # read-only; shows production's server
./scripts/onepassword-connect.sh create personal-infra-staging Kubernetes,Kubernetes-Staging
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
./scripts/hcloud-primary-ip.sh list
```

`personal-staging-ipv4` must show `auto_delete=false`. That is what keeps the
address across a destroy, which in turn keeps the DNS records and the IP
hardcoded in the staging MetalLB pool and Traefik values valid — and is why
`up` needs no manifest edit.

If it ever shows `auto_delete=true`:

```bash
./scripts/hcloud-primary-ip.sh protect <that-ip>
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

## Step 4 — Create the registry pull secret

The one manual step. `zot-registry-credentials` is **not** a 1Password item — it
is derived from `zot-auth`, which only exists once the operator has synced it,
which happens after the bootstrap has already finished. So it cannot be another
line in the bootstrap script.

```bash
export KUBECONFIG=$PWD/kubeconfig-staging.yaml

# wait for the operator to sync zot-auth
kubectl -n web get secret zot-auth

ZOT_PW=$(kubectl -n web get secret zot-auth -o jsonpath='{.data.password}' \
  | base64 -d | cut -d: -f2)

kubectl -n web create secret docker-registry zot-registry-credentials \
  --docker-server=zot.zachsexton.com \
  --docker-username=admin \
  --docker-password="$ZOT_PW" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n web delete pod -l app=ballroom-competition-web   # retry the pull
```

Staging pulls `zot.zachsexton.com/ballroom-competition-web` — the **production**
registry — so these really are production's Zot admin credentials.

> This does not survive a spin-down and must be repeated after every `up`. It can
> be folded into the bootstrap as an opportunistic wait-and-derive; see
> *Automating step 4* below.

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

## When it does not come up

`verify` names the pod behind each failing host and its last Warning event. The
common ones:

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `ImagePullBackOff` / `zot-registry-credentials` | step 4 not done, or redone after a rebuild | step 4 |
| `ContainerCreating` / `zot-auth not found` | 1Password operator not running | step 1, then `./scripts/staging.sh up` |
| every host fails TLS | cert-manager has no Cloudflare token | check `cloudflare_api_token` is set in the tfvars, then `up` |
| certificates stuck `READY=False` | stale ACME challenges from before the token existed | `kubectl -n web delete challenge,order,certificaterequest --all` |
| `argocd-staging` returns 502 | the ingress is on port 443 | must be port 80: the bootstrap sets `server.insecure`, so argocd-server speaks plain HTTP |
| Traefik LoadBalancer stuck `<pending>` | MetalLB pool does not match the real address | `./scripts/set-env-ip.sh staging <ip>`, commit, push |

Useful:

```bash
./scripts/staging.sh status
./scripts/staging.sh ssh
./scripts/staging.sh kubeconfig
kubectl -n argocd get applications
```

---

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
