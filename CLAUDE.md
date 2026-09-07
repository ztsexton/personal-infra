# Personal Infrastructure

## Overview

This repo manages personal project infrastructure via Terraform (Cloudflare DNS + Hetzner VPS) and Kubernetes manifests synced by ArgoCD. All application changes flow through ArgoCD GitOps — push manifest changes to `master` and ArgoCD auto-syncs.

## Working conventions

**Never hand over commands to paste into a terminal. Write a script.**

Anything the user has to run goes in `scripts/` as a committed, executable
script — not a fenced block of shell to copy. This applies to one-off and
"just this once" operations too; those are exactly the ones that end up
undocumented, and this repo has already been bitten by it (the registry pull
secret existed only as a remembered `kubectl` command, in no repository, and
had to be reconstructed from scratch during a rebuild).

A script written for this purpose should:

- take a subcommand rather than positional guesswork, and print usage with no arguments
- have a read-only mode (`show`, `check`, `status`) that changes nothing
- verify its preconditions and fail with the fix in the message, not a stack trace
- back up or snapshot before mutating anything, and re-read afterwards to confirm
  the change landed rather than trusting the exit code
- never print secret values; report shape (which keys, which registries, lengths)

Prefer extending an existing script over adding a near-duplicate.

## Architecture

- **Servers**: Hetzner Cloud VPS — production (ccx23 dedicated CPU) + staging (cpx21 shared CPU), both in Ashburn VA
- **Kubernetes**: k3s (single-node per environment, built-in Traefik disabled)
- **GitOps**: ArgoCD with app-of-apps pattern (separate root per environment)
- **Ingress**: Traefik (Helm-managed, 2 replicas, LoadBalancer via MetalLB)
- **TLS**: cert-manager + Let's Encrypt + Cloudflare DNS01 challenge
- **Secrets**: 1Password Operator syncs from 1Password vault to k8s secrets
- **Database**: PostgreSQL 16 via Crunchy Data PGO operator (persistent local-path storage)
- **Logging**: Fluent Bit + Loki + Grafana (grafana.zachsexton.com)
- **Registry**: Self-hosted Zot at zot.zachsexton.com (private, htpasswd auth)
- **DNS**: Cloudflare (DNS-only mode, no proxy) — production domains point to prod IP, *-staging subdomains to staging IP
- **Terraform State**: per-environment. Production in Scalr (zsexton.scalr.io); staging and sandbox local

## Key Directories

```text
terraform/modules/environment/      # Reusable env: primary IP, server, DNS, cluster bootstrap
terraform/envs/production/          # Production root (state in Scalr, applied via Scalr)
terraform/envs/staging/             # Staging root (local state, applied locally)
terraform/envs/sandbox/             # Throwaway root for testing create/destroy locally
k8s/argocd/production/              # ArgoCD Application CRs for production
k8s/argocd/staging/                 # ArgoCD Application CRs for staging
k8s/apps/base/                      # Shared app manifests (deployments, services, secrets)
k8s/apps/overlays/production/       # Production ingress (original hostnames)
k8s/apps/overlays/staging/          # Staging ingress (*-staging hostnames)
k8s/cert-manager/shared/            # ClusterIssuers + 1Password items
k8s/cert-manager/production/        # Production certificates
k8s/cert-manager/staging/           # Staging certificates
k8s/networking/metallb/production/  # MetalLB config with prod IP
k8s/networking/metallb/staging/     # MetalLB config with staging IP
k8s/postgres/                       # PostgresCluster CRs (managed by PGO operator)
k8s/namespaces/                     # Namespace definitions (web, infra)
scripts/                            # Operational helper scripts
```

## Domains

| Domain            | Usage                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| zachsexton.com    | Personal site, subdomains for services (argocd, zot, spotifybutler, etc) |
| petfoodfinder.app | Ballroom competition web app (currently hosted here)                     |
| vigilo.dev        | Vigilo project placeholder                                               |

## How Changes Flow

### Application/Kubernetes changes

1. Edit manifests under `k8s/`
2. Push to `master`
3. ArgoCD auto-syncs (prune + self-heal enabled)

### Infrastructure changes (DNS, server)

1. Edit `terraform/modules/environment/` (shared) or the relevant `terraform/envs/<env>/`
2. `cd terraform/envs/<env> && terraform plan && terraform apply`

Each environment is a separate root module with its own state, so `destroy` in one
cannot reach another. Production runs through Scalr; staging and sandbox run
locally. See `terraform/README.md` for setup and the migration runbook.

### Adding a new app

1. Create deployment, service manifests in `k8s/apps/base/<app-name>/`
2. Create ingress in both `k8s/apps/overlays/production/ingress/` and `k8s/apps/overlays/staging/ingress/`
3. Add the new resources to the base and overlay `kustomization.yaml` files
4. If the app needs a DNS record, add it to the `dns_records` map in `terraform/envs/production/main.tf` and `terraform/envs/staging/main.tf`
5. If using a custom domain, add Certificate resources in `k8s/cert-manager/production/` and `k8s/cert-manager/staging/`
6. If pulling from the private registry, reference `zot-registry-credentials` imagePullSecret
7. If the app needs secrets, create a `OnePasswordItem` CR in `k8s/apps/base/<app-name>/`

### Adding a new DNS record

1. Add an entry to the `dns_records` map in `terraform/envs/production/main.tf`
2. Add the `*-staging` counterpart to `terraform/envs/staging/main.tf`
3. Records automatically point at that environment's primary IP; `proxied = false`
   is set for all of them (DNS-only mode)

## ArgoCD Sync Wave Order

| Wave | Resources                                                         |
| ---- | ----------------------------------------------------------------- |
| -2   | Root application                                                  |
| -1   | Traefik ingress controller                                        |
| 0    | cert-manager, 1Password operator                                  |
| 1    | MetalLB, PGO operator                                             |
| 2    | MetalLB config, Postgres cluster, Loki, Fluent Bit, Grafana, apps |

## Secret Management

Secrets use the 1Password Operator. Never commit secrets to git.

- **OnePasswordItem CRs** define which 1Password items to sync
- Items live in the `Kubernetes` vault in 1Password
- Path format: `vaults/Kubernetes/items/<item-name>`
- Bootstrap secrets (1Password Connect token + credentials) are created by Terraform

Current 1Password-synced secrets:

- `cloudflare-api-token` — Cloudflare DNS API token (cert-manager namespace)
- `zot-auth` — Zot htpasswd file (web namespace)
- `zot-registry-credentials` — Docker config for pulling from Zot (web namespace)
- `ballroom-competition-web-firebase` — Firebase env vars (web namespace)

## Server Access

```bash
# SSH to production server
./scripts/personal-prod-server.sh

# SSH to staging server
./scripts/personal-web-server.sh

# Get kubeconfig for local kubectl access. k3s is installed with
# --tls-san <public ip>, so the rewritten server address passes cert validation.
cd terraform/envs/<env> && eval "$(terraform output -raw kubeconfig_command)"
```

## Terraform Variables

Production's values live in Scalr. For staging and sandbox, copy
`terraform.tfvars.example` in the env directory and fill it in (gitignored).
Key variables:

- `hcloud_token`, `ssh_public_key`, `ssh_private_key` — Hetzner access
- `k3s_token` — k3s cluster join token
- `argocd_admin_password_bcrypt` — ArgoCD admin password (bcrypt hash)
- `ssh_private_key` — used by Terraform to run the cluster bootstrap over SSH
- `cloudflare_api_token` — Cloudflare DNS management
- `cloudflare_zone_id_*` — Zone IDs for each domain
- `onepassword_connect_token`, `onepassword_credentials_json` — 1Password Connect

## Common Tasks

### Update an app's Docker image tag

Edit the `image:` field in the app's `deployment.yaml` under `k8s/apps/base/<app>/` (shared across environments).

### Spin staging up or down

```bash
./scripts/staging.sh up       # ~4 min: address, server, k3s, Argo CD, root app
./scripts/staging.sh down     # destroy the server, keep the address (~90% saving)
./scripts/staging.sh status
```

Repeatable: `down` keeps the primary IP, so the IP hardcoded in the staging
manifests stays valid and `up` needs no manual step. Only the Hetzner and
Cloudflare credentials are supplied by hand; the SSH keypair, k3s token and Argo
CD password are generated.

### Troubleshoot ArgoCD

```bash
./scripts/archive/diagnose_argo.sh
```

### Troubleshoot ingress/networking

```bash
./scripts/archive/diagnose_ingress.sh
```

### Re-run the cluster bootstrap

Set the new values in the env's `terraform.tfvars` and re-apply; the bootstrap is
idempotent and re-runs whenever its inputs change.

```bash
cd terraform/envs/<env> && terraform apply
```

## PostgreSQL (PGO)

The Crunchy Data PGO operator manages PostgreSQL. Cluster definitions live in `k8s/postgres/`.

- **Operator**: Installed via Kustomize from the PGO examples repo (sync wave 1)
- **Cluster CR**: `k8s/postgres/ballroom-cluster.yaml` creates a single-instance PostgreSQL 16
- **Storage**: PVCs use `local-path` StorageClass (data persists at `/opt/local-path-provisioner/` on the VM)
- **Credentials**: PGO auto-generates a secure password and creates secret `ballroom-db-pguser-ballroom` in the `web` namespace
- **Connection**: The ballroom app reads `DATABASE_URL`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` from the PGO-generated secret
- **Service**: `ballroom-db-primary.web.svc` (internal cluster DNS)
- **Backups**: pgBackRest with local repo (future improvement: add S3 off-site backup)

### Adding a new database

1. Create a new PostgresCluster CR in `k8s/postgres/`
2. Define users and databases in the `spec.users` array
3. PGO creates secrets named `<cluster>-pguser-<username>` with connection details
4. Reference the secret in your app's deployment env vars

## Logging (Loki + Fluent Bit + Grafana)

Container logs are collected and searchable via Grafana at `grafana.zachsexton.com`.

- **Fluent Bit**: DaemonSet that tails `/var/log/containers/*.log`, enriches with k8s metadata, ships to Loki
- **Loki**: Log storage in monolithic (single-binary) mode with filesystem PVC on `local-path`
- **Grafana**: UI at `grafana.zachsexton.com` (login required, default admin/admin)
- **Namespace**: All three run in `monitoring`

Apps just need to log to stdout (JSON preferred via pino). No app-side log shipping config needed.

### Querying logs in Grafana

1. Go to `grafana.zachsexton.com` → Explore → select Loki datasource
2. Use LogQL: `{namespace="web", app="ballroom-competition-web"}`
3. Filter by pod: `{pod="ballroom-competition-web-xxx"}`

## Important Notes

- The k3s built-in Traefik is disabled — Traefik is managed via Helm through ArgoCD
- MetalLB binds each server's external IP as the LoadBalancer IP (per-environment config)
- **That IP is hardcoded in two places per environment** — `k8s/argocd/<env>/traefik.yaml`
  (`loadBalancerIP`) and `k8s/networking/metallb/<env>/addresspool.yaml`. Use
  `./scripts/setup/set-env-ip.sh <env> <ip>` to change both; missing one leaves Traefik's
  LoadBalancer pending with every ingress down
- **Hetzner primary IPs must have `auto_delete = false`** or destroying a server
  releases its address, invalidating those manifests and every DNS record. Staging
  lost its address this way. Check with `./scripts/setup/hcloud-primary-ip.sh list`;
  environments built by `modules/environment` manage the IP as its own resource
- All TLS certificates are per-domain for independent renewal
- Zot registry has a 2GB upload limit configured via Traefik middleware
- ArgoCD runs in insecure mode (TLS terminated at Traefik)
- The `web` namespace is for applications, `infra` is for infrastructure components
