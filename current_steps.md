# Current steps

Everything waiting on you, in the order worth doing it. Claude keeps this file
updated — if something here is stale, that is a bug in the file.

Last updated: 2026-09-09. ballroom-progress-tracker is live at
tracker-staging.zachsexton.com and all 9 staging hosts serve over valid TLS.

---

## 1. Confirm the OVH consumer key is in 1Password

The working consumer key exists **only** in
`terraform/envs/staging-ovh/terraform.tfvars`, which is gitignored. Lose that
file and staging cannot be rebuilt without going through the browser
authorisation flow again.

**Check, then add if missing:**

```bash
eval $(op signin)
./scripts/setup/ovh-credentials.sh show
```

It lists the item's fields and their sizes. If `consumer key` is absent, copy it
from `terraform/envs/staging-ovh/terraform.tfvars` into the OVH item in
`Dev Vault` alongside the application key and secret.

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

- **The tracker's e2e suite has been failing since 2026-09-08 06:53.**
  `e2e/audit.spec.ts:17` times out on a `locator.click` after 240s. It fails on
  every branch including dependabot's, so it predates the platform-admin work
  and tonight's deployment changes. It means e2e currently gates nothing — a
  merge can go green on `checks` while e2e has been red for a day.

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

- **PR #16 merged and deployed** — the platform console is live at
  `/platform/studios`, and `zsexton2011@gmail.com` is now a platform admin, so
  it is actually reachable. That grant is re-asserted on every app start, so it
  holds whichever tenant the account is signed into.
- **A deploy completed with no intervention** for the first time: merge → CI →
  GHCR → manifests → Argo → migration → pod, all unattended. That confirms the
  Traefik `publishedService` fix was the cause of the sync deadlock rather than
  something needing per-deploy nursing.

- **Argo CD can complete a sync again, in both environments.** Traefik was not
  publishing its address onto Ingress `status.loadBalancer`, so Argo judged
  every Ingress `Progressing` forever and `PruneLast=true` held each sync open
  indefinitely. Two bugs: `publishedService` was never enabled, and the Helm
  keys were `kubernetesingress`/`kubernetescrd` where the chart wants
  `kubernetesIngress`/`kubernetesCRD` — Helm drops unknown keys silently, so
  everything under them, including `allowExternalNameServices`, had never taken
  effect in either environment.
- **Zot is finally gone from production**, 182 days after being removed from
  git. It was never a Zot problem: the prune was queued behind ingress health
  that could not arrive. Production now reports "successfully synced (no more
  tasks)".
- **`INFRA_REPO_PAT` is set on the tracker repo**, which was the last thing
  blocking automatic deploys.
- **Auto-deploy works end to end.** Push to `main` in the tracker repo →
  CI → image to GHCR → manifests updated here → Argo syncs → migration hook →
  new pod. Confirmed by `/api/health` reporting the deployed build:
  `{"ok":true,"db":"connected","version":"main-ef50d01"}`.

- **ballroom-progress-tracker is live** at tracker-staging.zachsexton.com, with
  the studio and an admin account created at app startup rather than by a seed
  job. `/`, `/signin` and `/api/health` all 200.

- Staging moved to an OVH VPS-1: $5.85/mo against $37.49 on Hetzner `ash`.
  All 8 staging URLs serve over valid TLS.
- `argocd.zachsexton.com` works again after six months — three separate faults.
- Hetzner staging destroyed, including the idle primary IP that billed $0.60/mo.
- `staging.petfoodfinder.app` now resolves; that was router-level negative DNS
  caching, not a misconfiguration.
