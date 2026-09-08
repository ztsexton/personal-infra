# Running staging on OVH

Ordering an OVH VPS-1, putting the same k3s + Argo CD on it, and moving the
staging hostnames over.

This **replaces** Hetzner staging rather than running beside it. Both roots
would otherwise own the same eight Cloudflare records and the same
`k8s/argocd/staging` manifests, and whichever applied last would win.

---

## Before you start

You need the OVH API credentials in 1Password (`Dev Vault`, item title
containing "ovh") with fields labelled `Application Key`, `Application Secret`
and `Consumer Key`.

Everything else — the Cloudflare token, the zone ids, the 1Password Connect
token and credentials — is copied automatically from
`terraform/envs/staging/terraform.tfvars` the first time any command runs. The
k3s token and the Argo CD admin password are generated.

---

## Step 1 — Get a consumer key that can order

The key currently in the vault is scoped to `/domain/*` and `/hosting/web/*`
only. It cannot touch `/vps` or `/order`, so the order would fail partway
through. A consumer key's scopes are fixed when it is created and cannot be
widened, so it has to be replaced.

**1.1** Request a new one with the right scopes:

```bash
./scripts/setup/ovh-credentials.sh request staging-ovh
```

This needs only the *application* key, so it works even though the current
consumer key grants nothing. It prints a validation URL.

**1.2** Open that URL in a browser and log in to OVH.

The key is inert until you do. There is no way to skip this — it is what stops
an application key alone from being enough to act on the account.

**1.3** Confirm it worked:

```bash
./scripts/setup/ovh-credentials.sh check staging-ovh
```

Pass the env name — `request` writes the new key to that env's tfvars, so a bare
`check` would test the *old* key still sitting in 1Password and tell you the new
one is broken.

You want every probe to say `ok`. Anything `FORBIDDEN` means the grant did not
take; repeat 1.1.

**1.4** Put the new consumer key into 1Password so it survives a rebuild.
`request` wrote it to tfvars, which is gitignored and therefore not a home for
it. Run `./scripts/setup/ovh-credentials.sh show` to check the field is there.

---

## Step 2 — Order the VPS and build the cluster

**2.1** Look at what will be ordered and what it costs:

```bash
./scripts/staging-ovh.sh plan
```

Expect `$5.85/mo` — $5.35 for the plan plus a mandatory $0.50 backup addon —
and `Plan: 2 to add`.

**2.2** Order it:

```bash
./scripts/staging-ovh.sh up
```

This asks you to type `order` before spending anything. Then it:

1. places the order and waits for OVH to deliver it
2. reads the address from `/vps/{name}/ips` and the image id from
   `/vps/{name}/images/available`, and writes both to tfvars
3. applies again — reinstalling with our SSH key and `doNotSendPassword`
4. uploads and runs the k3s install over SSH
5. installs 1Password Connect, Argo CD and the root Application

Two applies is forced, not a choice: the provider refuses `public_ssh_key`
without `image_id`, and `image_id` is only listed by an endpoint that needs the
VPS to already exist.

It prints the Argo CD admin password **once**.

**2.3** Check it:

```bash
./scripts/staging-ovh.sh status
```

`ssh (22)` and `k3s (6443)` should both be `open`.

At this point the cluster is running but **nothing is routed to it**. The
staging manifests still hardcode the Hetzner address, so Traefik's LoadBalancer
is pending and DNS still points elsewhere. That is expected.

---

## Step 3 — Make it the live staging

**3.1** Spin the Hetzner box down first, so two clusters are not both trying to
serve:

```bash
./scripts/staging.sh down
```

**3.2** Take the hostnames over:

```bash
./scripts/staging-ovh.sh promote
```

Asks you to type `promote`, then:

1. points `k8s/argocd/staging/traefik.yaml` and the MetalLB pool at the OVH address
2. commits and pushes to `master` — Argo CD reads from GitHub, so this is what
   makes it real
3. moves the eight staging DNS records
4. waits for Argo CD to sync, then verifies every URL

**3.3** Confirm:

```bash
./scripts/staging-ovh.sh verify
```

Every host should show `DNS=ok` and a 2xx/3xx. TLS is validated for real — a
self-signed certificate counts as a failure, because that is exactly what a
broken DNS-01 challenge produces.

---

## Rolling back to Hetzner

```bash
./scripts/staging.sh up          # rebuilds and retakes the manifests + DNS
./scripts/staging-ovh.sh destroy # terminate the OVH service
```

`staging.sh up` rewrites the same two manifests and reapplies the same DNS
records, so it takes them straight back.

---

## Things that differ from Hetzner

**There is no `down`.** An OVH VPS is a subscription, not an hourly instance.
Stopping it saves nothing, and terminating a committed term still bills to the
end of it. `staging-ovh.sh destroy` is a cancellation.

We order on `pricing_mode = "default"` — month-to-month at $5.35 rather than
$4.54 on a 12-month commitment. The $0.81/mo buys the ability to walk away.

**Every rebuild changes the address.** Hetzner primary IPs are separate
resources that survive destroying the server, which is what makes
`staging.sh up` a single command. OVH's address belongs to the VPS, so a rebuild
means `promote` again to rewrite the manifests and DNS.

**No cloud-init.** `ovh_vps` has no `user_data`, so the k3s install is uploaded
and run over SSH. Both providers render the same
`terraform/modules/environment/templates/install-k3s.sh.tmpl`, so the firewall
rules and k3s flags cannot drift apart.

**The provider exposes no IP** — not on the resource, not on the data source. It
is read from the API and passed back in as `vps_host`.

---

## If something breaks

| Symptom | Where to look |
| ------- | ------------- |
| Order fails with 403 | `./scripts/setup/ovh-credentials.sh check staging-ovh` — the consumer key scopes |
| A rule looks granted but 403s | OVH's `/x/*` matches everything *under* `/x`, not `/x` itself. Both are needed, and `request` asks for both |
| `up` stops at "no IPv4 address yet" | OVH is still provisioning; re-run in a minute, it is resumable |
| No image matches | The script lists what is available; set `vps_os` in tfvars to one of those names verbatim |
| k3s installed but Argo CD missing | `./scripts/staging-ovh.sh ssh` then `tail -100 /var/log/cluster-bootstrap.log` |
| Certificates never issue | `KUBECONFIG=kubeconfig-staging-ovh.yaml ./scripts/certs.sh status` — usually the Cloudflare token is missing |
| Secrets missing | `KUBECONFIG=kubeconfig-staging-ovh.yaml ./scripts/secrets.sh status` |
