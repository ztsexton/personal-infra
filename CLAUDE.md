# Personal Infrastructure

## Overview

This repo manages personal project infrastructure via Terraform (Cloudflare DNS + Hetzner VPS) and Kubernetes manifests synced by ArgoCD. All application changes flow through ArgoCD GitOps — push manifest changes to `master` and ArgoCD auto-syncs.

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
- **Terraform State**: Scalr remote backend (zsexton.scalr.io)

## Key Directories

```text
terraform/                          # Hetzner servers, Cloudflare DNS, cloud-init bootstrap
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

1. Edit Terraform files under `terraform/`
2. Run `terraform plan` and `terraform apply` (state in Scalr)

### Adding a new app

1. Create deployment, service manifests in `k8s/apps/base/<app-name>/`
2. Create ingress in both `k8s/apps/overlays/production/ingress/` and `k8s/apps/overlays/staging/ingress/`
3. Add the new resources to the base and overlay `kustomization.yaml` files
4. If the app needs a DNS record, add prod + staging records in `terraform/cloudflare.tf`
5. If using a custom domain, add Certificate resources in `k8s/cert-manager/production/` and `k8s/cert-manager/staging/`
6. If pulling from the private registry, reference `zot-registry-credentials` imagePullSecret
7. If the app needs secrets, create a `OnePasswordItem` CR in `k8s/apps/base/<app-name>/`

### Adding a new DNS record

1. Add `cloudflare_record` resource in `terraform/cloudflare.tf`
2. Production records point to `hcloud_server.production.ipv4_address`
3. Staging records (e.g. `*-staging.zachsexton.com`) point to `hcloud_server.staging.ipv4_address`
4. Use `proxied = false` (DNS-only mode)

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

# Get kubeconfig for local kubectl access
scp root@<server-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

## Terraform Variables

All sensitive values are stored in Scalr. Key variables:

- `hcloud_token`, `ssh_public_key`, `ssh_private_key` — Hetzner access
- `k3s_token` — k3s cluster join token
- `argocd_admin_password_bcrypt` — ArgoCD admin password (bcrypt hash)
- `cloudflare_api_token` — Cloudflare DNS management
- `cloudflare_zone_id_*` — Zone IDs for each domain
- `onepassword_connect_token`, `onepassword_credentials_json` — 1Password Connect

## Common Tasks

### Update an app's Docker image tag

Edit the `image:` field in the app's `deployment.yaml` under `k8s/apps/base/<app>/` (shared across environments).

### Troubleshoot ArgoCD

```bash
./scripts/diagnose_argo.sh
```

### Troubleshoot ingress/networking

```bash
./scripts/diagnose_ingress.sh
```

### Update 1Password secrets on the server

```bash
./scripts/update-1password-secrets.sh <credentials.json> <connect-token>
```

### Update Cloudflare API token

```bash
./scripts/update-cloudflare-token.sh
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
- All TLS certificates are per-domain for independent renewal
- Zot registry has a 2GB upload limit configured via Traefik middleware
- ArgoCD runs in insecure mode (TLS terminated at Traefik)
- The `web` namespace is for applications, `infra` is for infrastructure components
