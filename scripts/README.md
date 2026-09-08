# scripts

Anything you need to run lives here as a script. Nothing in this repo should
require pasting commands into a terminal — if you find yourself doing that, the
script is missing.

## Everyday

Run these regularly. All default to staging and take `KUBECONFIG` to point
elsewhere.

| Script | What it does |
| ------ | ------------ |
| `staging.sh` | The lifecycle. `up`, `down`, `relocate`, `status`, `verify`, `ssh`, `kubeconfig`, `nuke` |
| `certs.sh` | `status`, `unstick`, `watch` — certificates and stuck ACME challenges |
| `unstick-rollout.sh` | `status`, `fix` — StatefulSet rollouts that can never finish because the pod blocking them is the one the old spec produced |
| `secrets.sh` | `status`, `sources`, `resync` — what exists, where it comes from, what is orphaned |
| `staging-ovh.sh` | The OVH VPS trial. `plan`, `up`, `status`, `ssh`, `kubeconfig`, `destroy` |
| `personal-prod-server.sh` | SSH to production |
| `personal-web-server.sh` | SSH to staging |

The two you will reach for most:

```bash
./scripts/staging.sh up        # build staging from nothing, ~4 min
./scripts/staging.sh verify    # every configured URL, with real TLS validation
```

## setup/

Occasional, mostly one-time. You will not run these in a normal week.

| Script | When |
| ------ | ---- |
| `onepassword-connect.sh` | Creating a 1Password Connect server and token for an environment |
| `ovh-credentials.sh` | Finding the OVH API credentials in 1Password, proving they can order, writing them to tfvars |
| `ovh-api.py` | Signed OVH API calls. Called by the two scripts above, not directly |
| `registry-auth.sh` | Changing the container-registry credential in 1Password |
| `hcloud-primary-ip.sh` | Listing Hetzner primary IPs, or protecting one from deletion |
| `scalr-workspace.sh` | Reading or changing Scalr workspace settings |
| `set-env-ip.sh` | Writing an environment's IP into the manifests that hardcode it. Normally called for you by `staging.sh up` |
| `zot-htpasswd.sh` | Regenerating the Zot htpasswd entry when rotating that password |

## lib/

Called by the scripts above, not directly.

| Script | What it is |
| ------ | ---------- |
| `verify-env.sh` | The list of staging hostnames and the TLS check, shared by `staging.sh verify` and `staging-ovh.sh verify` so the list exists once |
| `tfvars.py` | Reading and writing single values in a tfvars file. Exists because the obvious `grep -oP '"\K[^"]*"'` stops at the first escaped quote, which silently truncates the 1Password credentials JSON to two characters |

## archive/

Finished one-offs and superseded tooling. Kept because they record how something
was done, not because you should run them.

| Script | Why it is here |
| ------ | -------------- |
| `tf-preflight.sh` | Gated the production migration onto per-environment roots. That migration is applied |
| `tf-split-staging.sh` | Removed staging from production's Terraform state. Done |
| `tf-migration-ids.sh` | Produced the import IDs for that migration |
| `import_cloudflare_settings.sh` | One-time Cloudflare import |
| `diagnose_argo.sh` | Predates the current bootstrap — looks for a `bootstrap` journal tag and a k3s-managed Traefik HelmChart, neither of which exists now. `staging.sh status` and `secrets.sh status` replace it |
| `diagnose_ingress.sh` | Same vintage. `staging.sh verify` replaces it |

`setup-zot-registry-credentials.sh` was deleted rather than archived: it derived
the registry password from the `zot-auth` secret with `cut -d: -f2`, but that
secret holds an htpasswd line, so the second field is a bcrypt hash rather than a
password. Any pull secret built that way fails authentication. The credential is
now a `OnePasswordItem`; see `setup/registry-auth.sh`.

## Conventions

A script here should:

- take a subcommand, and print usage when given none
- have a read-only mode that changes nothing (`status`, `show`, `check`)
- check its preconditions and fail with the fix in the message
- snapshot before mutating, and read back afterwards to confirm rather than
  trusting an exit code
- never print secret values — report shape instead

Prefer extending one of these over adding a near-duplicate.
