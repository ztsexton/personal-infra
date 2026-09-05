# Terraform

Hetzner servers, Cloudflare DNS, and the cluster bootstrap (k3s → Argo CD → app-of-apps).

## Layout

```text
terraform/
  modules/environment/     # one environment: primary IP, server, DNS, cluster bootstrap
    templates/
      cloud-init.yaml.tmpl        # k3s only, no application secrets
      bootstrap-cluster.sh.tmpl   # Argo CD + 1Password secrets + root Application
      argocd-values.yaml.tmpl
      root-app.yaml.tmpl
  envs/production/         # state in Scalr, applied through Scalr
  envs/staging/            # state local by default, applied from a laptop
  envs/sandbox/            # throwaway, local state, safe to destroy
  backends/                # optional backend configs
```

Each `envs/*` directory is an independent root module with its own state. A
`terraform destroy` in one cannot reach the others — that separation is the whole
point of the layout.

## Local setup

```bash
# 1.5.x or newer; the roots pin >= 1.5.0, < 2.0.0
terraform version

cd terraform/envs/staging          # or sandbox
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars           # gitignored

terraform init
terraform plan
```

Production is the exception: it uses the Scalr `remote` backend, so `terraform
apply` there streams a run executed on Scalr rather than on your machine. That is
deliberate. Authenticate with:

```bash
terraform login zsexton.scalr.io
```

The token in `~/.terraform.d/credentials.tfrc.json` expires; if `terraform init`
reports `unauthorized`, that is why.

## The sandbox loop

The sandbox exists so the full create → bootstrap → destroy cycle can be
exercised without touching anything real. Nothing in it is protected.

```bash
cd terraform/envs/sandbox
terraform apply                     # ~5 min: server, k3s, Argo CD, root app
eval "$(terraform output -raw kubeconfig_command)"
kubectl --kubeconfig kubeconfig-sandbox.yaml -n argocd get applications
terraform destroy                   # removes server, primary IP, DNS
```

`dns_records` is empty by default so a sandbox never claims a hostname that
production or staging serves.

One caveat: `git_root_app_path` defaults to `k8s/argocd/staging`, whose MetalLB
pool and Traefik `loadBalancerIP` are pinned to staging's address. In a sandbox
those will not match, so ingress will not come up — everything upstream of it
(k3s, Argo CD, 1Password, cert-manager, Postgres, the app deployments) still gets
exercised. Add a `k8s/argocd/sandbox` tree if you need working ingress there.

## Why the IPs are separate resources

`k8s/networking/metallb/*/addresspool.yaml` and `k8s/argocd/*/traefik.yaml`
hardcode each environment's public IP. Hetzner hands out a **new** address every
time a server is created, so with the IP attached to the server, destroying and
recreating one meant hand-editing and committing manifests before Argo CD could
converge.

`hcloud_primary_ip` is created independently of the server with
`auto_delete = false`, so the address outlives the server. Staging carries
`prevent_destroy` on top of that (`protect_primary_ip = true`); the sandbox does
not, because it needs `destroy` to actually complete.

Production does **not** manage a primary IP yet (`manage_primary_ip = false`) —
adopting one would power-cycle the running server. See *Production safety* below.

## What the bootstrap does

`cloud-init` installs k3s and nothing else:

- pins the k3s version rather than tracking the stable channel
- `--disable traefik` (Argo CD manages the Traefik chart) **and
  `--disable servicelb`** — leaving klipper-lb enabled makes it and MetalLB fight
  over every `LoadBalancer` service
- `--tls-san <public ip>`, without which a kubeconfig rewritten to the public
  address fails certificate validation
- re-enables ufw forwarding and allows the pod/service CIDRs; `ufw enable`
  otherwise sets the FORWARD policy to DROP and breaks pod networking
- drops a marker at `/var/lib/k3s-bootstrap-complete`

Terraform then runs `bootstrap-cluster.sh` over SSH (`modules/environment/bootstrap.tf`):

1. waits for the marker, failing the apply if k3s never came up
2. creates the 1Password Connect secrets — **before** the root Application, because
   `onepassword-operator` syncs at wave 0 and mounts them
3. installs Argo CD from a pinned chart version, with `server.insecure` set in the
   Helm values rather than patched onto `argocd-cmd-params-cm` afterwards (Argo CD
   reads that ConfigMap only at startup, so a post-install patch leaves
   `argocd-server` serving TLS while Traefik speaks plain HTTP to it)
4. deletes `argocd-initial-admin-secret`
5. applies the root Application last

No application secret goes into `user_data`. Hetzner keeps `user_data` readable
through the console and API for the life of the server, so the 1Password token,
credentials JSON and Argo CD password hash all travel over SSH instead and are
shredded from the box afterwards.

## Production safety

Production is adopted by this restructure **without any change to its
infrastructure**. Two module switches are deliberately off in
`envs/production/main.tf`:

| Switch | Off because |
| --- | --- |
| `manage_primary_ip` | Adopting a primary IP rewrites the server's `public_net`, and the provider powers the server off and on again to reassign the address. Production keeps the IP Hetzner already gave it, so no `public_net` block is emitted at all. |
| `bootstrap_cluster` | The bootstrap would SSH into the live cluster and run `helm upgrade --install argocd`, replacing the existing kubectl-installed Argo CD. Production's cluster is already running and is not re-bootstrapped. |

A third hazard is not a switch but a `lifecycle` rule on the server. Two
attributes are **ForceNew** on `hcloud_server`, and either one alone would have
destroyed and recreated the running production machine:

- **`user_data`** — read only at first boot, but stored as a hash and diffed
  forever after. Adopting a running server into this module renders a different
  cloud-init template than the one it booted with, which is by itself enough to
  trigger a rebuild.
- **`ssh_keys`** — `hcloud_ssh_key.public_key` is also ForceNew, and the Hetzner
  API stores the key **with a trailing newline**. A whitespace-only difference in
  `ssh_public_key` replaces the key, which turns the server's `ssh_keys` into
  "known after apply" and takes the server with it.

Both are ignored (`modules/environment/main.tf`), because neither affects a
running machine. Rebuild deliberately instead:

```bash
terraform apply -replace=module.env.hcloud_server.this
```

So production's move into the module is a **state-only refactor**. This has been
verified against the live state rather than assumed — with the staging resources
removed from state, the plan is:

```
Plan: 0 to add, 0 to change, 0 to destroy.
```

with every remaining action a `has moved to` line.

### Reproducing that check offline

`tf-preflight.sh plan` cannot drive a CLI plan against a remote-execution
workspace (see below), but the same check runs locally against a read-only copy
of the state:

```bash
cd terraform/envs/production
terraform state pull > /tmp/prod.tfstate          # read-only

# in a scratch copy of envs/production + modules/, with no backend block:
cp /tmp/prod.tfstate terraform.tfstate
terraform plan -refresh=false                      # no API calls
```

`ssh_public_key` must be byte-identical to what is in state, trailing newline
included, or the plan shows a spurious key replacement.

The trade-off: production does not yet get the stable primary IP or the rebuilt
bootstrap. Both land the next time production is rebuilt, deliberately and on a
schedule — not as a side effect of this refactor.

### The one way this could go wrong

`moved.tf` renames production's resources. A `moved` block whose `from` address is
not actually in state is **silently a no-op**, after which Terraform plans to
create the destination and destroy the untracked original.

This has been checked against the live Scalr state and all 15 blocks resolve:

```bash
./scripts/tf-preflight.sh addresses   # what is really in state
./scripts/tf-preflight.sh moved       # flags any `from` that is not there
```

Re-run `moved` if anything about the state changes before you migrate.

### What the workspace already guarantees

`./scripts/tf-preflight.sh workspace` reports the settings that matter:

| Setting | Value | Why it matters |
| --- | --- | --- |
| `auto_apply` | **false** | Nothing reaches production infrastructure without a human approving the run. This is the strongest guarantee in the whole migration — keep it false. |
| `execution_mode` | `remote` | Plans run on Scalr, not your laptop. |
| `trigger_prefixes` | `["terraform"]` | Still matches `terraform/envs/production`, so triggers need no change. |
| `working_directory` | `terraform` | The one thing that must change. |

Because `auto_apply` is false and Scalr runs dry runs on pull requests, **the
migration gate is the plan on a PR**: open one, read the plan, approve only if it
is empty.

Note that `tf-preflight.sh plan` cannot drive that gate from the CLI. A CLI-driven
run uploads only the current directory, which excludes
`../../modules/environment`, so the remote run cannot resolve the module. Either
gate on the PR dry run, or switch the workspace to local execution mode for the
duration of the migration.

## Migration runbook (one-time)

This layout replaces a single flat root that held production and staging in one
Scalr state.

### 0. Confirm the workspace is still safe

```bash
terraform login zsexton.scalr.io     # if the token has expired
./scripts/tf-preflight.sh workspace
```

`auto_apply` must read **false**. It already does, which means a push to `master`
queues a plan and stops — nothing is applied until someone approves it. That is
what makes the rest of this recoverable at every step.

Be aware that until step 3 is done, the plan will legitimately show the staging
resources being destroyed: they are in state but no longer in production's
configuration. Do not approve that run.

### 1. Point Scalr at the new directory

```bash
./scripts/scalr-workspace.sh show
./scripts/scalr-workspace.sh set-working-dir terraform/envs/production
./scripts/scalr-workspace.sh set-trigger-prefixes terraform/envs/production terraform/modules
```

Both trigger prefixes matter: `envs/production` sources `../../modules/environment`,
so without the second one a change to the shared module would alter production
without ever queueing a plan.

Every mutating command snapshots the workspace to `.scalr-backups/` first and
builds its payload from the live object, so no field is dropped.
`./scripts/scalr-workspace.sh restore <backup.json>` puts it back.

### 2. Verify the moved blocks against real state

```bash
./scripts/tf-preflight.sh addresses
./scripts/tf-preflight.sh moved
```

Fix `moved.tf` until nothing is reported MISSING. Do not skip this.

### 3. Split staging out of production's state

State-only; `terraform state rm` forgets a resource, it does not destroy it. The
staging server and DNS keep running and are adopted by `envs/staging` in step 5.

```bash
./scripts/tf-split-staging.sh check     # confirm all 10 are there
./scripts/tf-split-staging.sh remove    # prompts, backs the state up first
```

Order matters: run this only once Scalr reads the new layout for production. Run
it while `master` still carries the old flat root and the next plan will want to
recreate all ten as duplicates.

### 4. Gate, then apply production

Open a pull request. Scalr dry-runs it and the plan must read
**0 to add, 0 to change, 0 to destroy**. Anything else means stop — production's
adoption is a state-only refactor and any planned change is a bug in `moved.tf`
or in the two safety switches.

Approve and merge only on an empty plan. `moved.tf` can be deleted afterwards.

If you would rather gate from the CLI, switch the workspace to local execution
mode first, then `./scripts/tf-preflight.sh plan` works directly.

### 5. Rebuild staging

Staging is currently a bare k3s box with no Argo CD — the old
`cloud-init.yaml.tmpl` never installed it. Rebuilding it from scratch is both the
fix and the end-to-end test of the new bootstrap. It is entirely independent of
production: separate state, separate root, its own server.

```bash
cd terraform/envs/staging
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
terraform init

# Keep 178.156.242.161 so the staging manifests stay valid
terraform import 'module.env.hcloud_primary_ip.protected[0]' <STAGING_PRIMARY_IP_ID>
terraform apply -target='module.env.hcloud_primary_ip.protected[0]'   # sets auto_delete=false

# Import the existing DNS records
./../../scripts/tf-migration-ids.sh dns-imports    # prints the commands

# Delete the old staging server. The primary IP survives because auto_delete is
# now false. Then:
terraform apply
```

`terraform apply` finishes only once Argo CD is installed and the root
Application is applied. If the cluster does not come up, the apply fails — the
old bootstrap reported success on a broken cluster.
