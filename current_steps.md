# Current steps

Everything waiting on you, in the order worth doing it. Claude keeps this file
updated — if something here is stale, that is a bug in the file.

Last updated: 2026-09-09. ballroom-progress-tracker is live at
tracker-staging.zachsexton.com and all 9 staging hosts serve over valid TLS.

---

## 1. Add INFRA_REPO_PAT to the tracker repo

Pushing to `main` in `ballroom-progress-tracker` now builds an image **and**
updates the staging manifests to point at it — but the update step needs a
token to push to this repository, and that repo has no secrets at all:

```
$ gh secret list --repo ztsexton/ballroom-progress-tracker
(empty)
```

`ballroom-competition-web` already has an `INFRA_REPO_PAT` doing exactly this.
Copy the same token in:

```bash
gh secret set INFRA_REPO_PAT --repo ztsexton/ballroom-progress-tracker
```

Without it the build still publishes, but nothing redeploys — the symptom is a
green build and an unchanged pod.

---

## 2. Store the OVH consumer key in 1Password

The working consumer key exists **only** in
`terraform/envs/staging-ovh/terraform.tfvars`, which is gitignored. Lose that
file and staging cannot be rebuilt without going through the browser
authorisation flow again.

**Do:** add it to the OVH item in `Dev Vault` alongside the application key and
secret. `./scripts/setup/ovh-credentials.sh show` confirms the field landed.

---

## 3. Decide what to do about Zot in production

Zot was removed from git during the GHCR migration. The pod has been running
**182 days** since, and production's `apps` application has been `OutOfSync`
ever since because the prune never completed.

This is not urgent and nothing is broken by it, but production's GitOps is not
converged while it stands, so any future change to that app queues behind it.

**Decide:** prune it (it serves no images any more — both apps pull from GHCR),
or put it back in git if you still want a self-hosted registry.

---

## 4. Rotate the credentials exposed earlier

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

## Worth deciding, not blocking

- **Production's init.sql grants in the wrong database.** It runs every GRANT
  against `postgres` because it never switches database, so `ballroom_scorer`
  has no `ballroom` grant at all — it only works because its tables already
  exist. The staging overlay is fixed; production's is not, and re-running its
  databaseInitSQL is a deliberate act. The next app added there will hit this.
- **`*.staging.zachsexton.com` instead of `{app}-staging`.** No conflict exists
  today and none can — there is no wildcard DNS record, and an exact name beats
  a wildcard anyway. The argument is that a new staging app would then need only
  an ingress: no DNS record, no terraform apply, no certificate. Costs a new
  wildcard cert (a wildcard covers exactly one label) and renaming 9 hosts plus
  their auth origins.

## Recently finished

- **ballroom-progress-tracker is live** at tracker-staging.zachsexton.com, with
  the studio and an admin account created at app startup rather than by a seed
  job. `/`, `/signin` and `/api/health` all 200.

- Staging moved to an OVH VPS-1: $5.85/mo against $37.49 on Hetzner `ash`.
  All 8 staging URLs serve over valid TLS.
- `argocd.zachsexton.com` works again after six months — three separate faults.
- Hetzner staging destroyed, including the idle primary IP that billed $0.60/mo.
- `staging.petfoodfinder.app` now resolves; that was router-level negative DNS
  caching, not a misconfiguration.
