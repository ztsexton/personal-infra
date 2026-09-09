# Current steps

Everything waiting on you, in the order worth doing it. Claude keeps this file
updated — if something here is stale, that is a bug in the file.

Last updated: 2026-09-08, after retiring Hetzner staging and deploying
ballroom-progress-tracker to OVH staging.

---

## 1. Publish the first tracker image  ← blocking two things

`ghcr.io/ztsexton/ballroom-progress-tracker` does not exist yet, so the staging
deploy is stuck:

```
ballroom-progress-tracker-migrate-42svs   0/1   ImagePullBackOff
Back-off pulling image "ghcr.io/ztsexton/ballroom-progress-tracker:main"
```

That also holds the whole staging `apps` sync open, because the migration is a
PreSync hook — Argo waits for it before syncing anything else in that app.

**Do:** merge the workflow to `main` in `ztsexton/ballroom-progress-tracker`.
It is on `claude/notes-audit-chart-scope` as commit `c1dad5a`. The workflow
triggers on push to `main`; nothing publishes from any other branch.

Note that repository's default branch is `claude/ballroom-progress-tracker-g189tb`,
not `main` — so a PR opened with the default base will not trigger a publish.
Target `main` explicitly.

**Then:** nothing. Argo pulls the image, the migration runs, the app starts.

---

## 2. Create the app's session-signing secret

The deployment reads `BETTER_AUTH_SECRET` from a 1Password-synced secret that
does not exist yet. Without it the pod stays in `CreateContainerConfigError`,
even once the image is published.

**First, clean up after the failed attempt.** The run on 2026-09-08 created an
item with **no title** — `op` parses `--title` before it reads the template, so
the title in the template was ignored. That item holds a real generated secret
and `op item get` cannot find it by name.

```bash
eval $(op signin)
./scripts/setup/app-auth-secret.sh show
```

`show` now lists everything in the `Kubernetes` vault and flags anything
untitled. Delete the stray one in the 1Password app, then:

```bash
./scripts/setup/app-auth-secret.sh create
```

The script generates the value, stores it in vault `Kubernetes` as item
`ballroom-progress-tracker-auth`, and never prints it.

This path has still never completed successfully. There is no 1Password session
reachable from Claude's shell, so every fix has been written from `op --help`
rather than tested — four attempts so far, each failing differently. If it
fails again, running this once by hand is a reasonable way out:

```bash
op item create --category "Secure Note" --title ballroom-progress-tracker-auth \
  --vault Kubernetes "BETTER_AUTH_SECRET[password]=$(openssl rand -base64 32)"
```

---

## 3. Store the OVH consumer key in 1Password

The working consumer key exists **only** in
`terraform/envs/staging-ovh/terraform.tfvars`, which is gitignored. Lose that
file and staging cannot be rebuilt without going through the browser
authorisation flow again.

**Do:** add it to the OVH item in `Dev Vault` alongside the application key and
secret. `./scripts/setup/ovh-credentials.sh show` confirms the field landed.

---

## 4. Decide what to do about Zot in production

Zot was removed from git during the GHCR migration. The pod has been running
**182 days** since, and production's `apps` application has been `OutOfSync`
ever since because the prune never completed.

This is not urgent and nothing is broken by it, but production's GitOps is not
converged while it stands, so any future change to that app queues behind it.

**Decide:** prune it (it serves no images any more — both apps pull from GHCR),
or put it back in git if you still want a self-hosted registry.

---

## 5. Rotate the credentials exposed earlier

Several secrets were shown in full in a chat transcript during earlier work and
should be considered compromised. Staging's own values are gone with the
Hetzner environment, but these are still live and are now also used by OVH
staging:

- `hcloud_token` — full control of the Hetzner account, including production
- `cloudflare_api_token` — DNS for all three domains
- `onepassword_connect_token` — reads every item in the Kubernetes vault
- `onepassword_credentials_json`
- The Zot admin password (`admin` / a value pasted in chat)

The 1Password Connect token is the one to do first: it can read every secret
the cluster uses.

---

## Not blocking, but worth knowing

- **Production must never be rebuilt.** It is billed at its creation-date rate,
  and Hetzner raised prices on 15 June 2026. `protect_server = true` is applied
  and Hetzner-enforced. Fixes for that cluster have to arrive through Argo CD.
- **Production's Argo CD ingress fix is applied but its Scalr state is not.**
  The `protect_server` change was set directly through the Hetzner API so it is
  live; the next Scalr plan should show no change. If it shows a diff, stop and
  look rather than approving.
- **Hetzner staging is a template with nothing deployed.** `staging.sh up`
  rebuilds it, but doing so takes the staging hostnames back from OVH.

---

## Recently finished

- Staging moved to an OVH VPS-1: $5.85/mo against $37.49 on Hetzner `ash`.
  All 8 staging URLs serve over valid TLS.
- `argocd.zachsexton.com` works again after six months — three separate faults.
- Hetzner staging destroyed, including the idle primary IP that billed $0.60/mo.
- `staging.petfoodfinder.app` now resolves; that was router-level negative DNS
  caching, not a misconfiguration.
