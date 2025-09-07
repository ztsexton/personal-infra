# Personal Infrastructure

Infrastructure as Code (IaC) for personal multi-domain hosting. Current stack:

- Hetzner Cloud (Terraform) single VPS (can grow to small cluster)
- k3s (lightweight Kubernetes) installed via cloud-init
- Cloudflare DNS (Terraform) + DNS01 certificates via cert-manager
- Ingress (Traefik class) terminating TLS for multiple domains
- Git-based declarative manifests in `k8s/`

> NOTE: Previous Ansible + nginx + certbot approach is deprecated (see `ansible/DEPRECATED.md`).

## Current Domains

- zachsexton.com
- petfoodfinder.app
- vigilo.dev

## Layout

```text
terraform/     # Infra (server + DNS)
k8s/           # Kubernetes manifests (namespaces, apps, ingress, cert-manager)
ansible/       # Deprecated legacy configuration
scripts/       # Helper scripts (to be expanded)
```

## Terraform

Only provisions:

- Hetzner server + SSH key
- Cloudflare DNS A records + DNSSEC
- cloud-init user_data that installs k3s and basic firewall

Apply (local example):

```bash
cd terraform
terraform init
terraform apply
```

(Or via Scalr backend if configured.)

## Accessing the Cluster

After the server boots, retrieve kubeconfig:

```bash
ssh root@<server-ip> 'cat /root/.kube/config' > kubeconfig
# (Optional) adjust server endpoint if public IP not already substituted
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

cloud-init script replaces 127.0.0.1 with the public IP automatically (best-effort).

## Kubernetes Manifests

Key files:

- `k8s/namespaces/namespaces.yaml`
- `k8s/apps/*.yaml` (placeholder echo services now)
- `k8s/ingress/ingress.yaml` (multi-host Ingress + shared TLS secret)
- `k8s/cert-manager/clusterissuer.yaml` (ClusterIssuer using Cloudflare DNS01)

### Apply Core Stack

Install cert-manager (CRDs & controllers) BEFORE applying ClusterIssuer:

```bash
# Install cert-manager (version example; update as needed)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml
kubectl create namespace cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml

# Cloudflare API token secret (replace TOKEN_VALUE)
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token=TOKEN_VALUE

# Namespaces & apps
kubectl apply -f k8s/namespaces/namespaces.yaml
kubectl apply -f k8s/apps/

# ClusterIssuer
kubectl apply -f k8s/cert-manager/clusterissuer.yaml

# Ingress (requests certificate automatically)
kubectl apply -f k8s/ingress/ingress.yaml
```

Certificate issuance will create secret `multi-domain-tls` in `web` namespace.

### Traefik IngressClass

k3s ships with Traefik by default IF not disabled. Cloud-init disables it (`--disable traefik`). If you want to re-enable Traefik instead of a custom ingress controller, remove that flag and re-provision OR install your own controller (nginx ingress, Traefik Helm chart, Envoy Gateway). Adjust `ingressClassName` accordingly.

Currently `ingress/ingress.yaml` sets `ingressClassName: traefik`. If Traefik is disabled you must deploy an ingress controller that registers that class name or update the manifest.

## Adding a New App

1. Create a Deployment + Service YAML in `k8s/apps/<app>.yaml` (namespace `web`).
2. Add a new host rule in `k8s/ingress/ingress.yaml` under `spec.rules` and add the host to the TLS `hosts` list.
3. `kubectl apply -f k8s/apps/<app>.yaml` and re-apply ingress.
4. Add DNS A record in Terraform (or rely on external-dns later).

## External-DNS (Future Optional)

To auto-manage DNS when you scale or change Services, deploy external-dns with Cloudflare provider. Then you can omit manual A record additions (except initial bootstrap).

## cert-manager Notes

- Uses DNS01 challenge with Cloudflare token (least privilege: Zone DNS Edit only).
- Multi-domain cert stored in one secret; you can switch to per-domain certs by splitting Ingress resources.
- For wildcard support add `*.example.com` to Ingress TLS hosts and re-issue.

## Scaling Path

- Add second node: provision a new Hetzner server, install k3s agent using server token from `/var/lib/rancher/k3s/server/node-token` on the first node.
- Consider a small object storage or Longhorn if you introduce stateful workloads needing replication.
- Switch ingress controller if you want advanced features (e.g., NGINX or Envoy Gateway CRDs).

## Legacy (Deprecated)

The Ansible + nginx deployment has been retired. Files kept only for historical reference and gradual removal once confidence in k3s setup is established.

## Security Quick Wins

- Keep Cloudflare proxy (orange-cloud) ON for public domains.
- Enforce TLS (HTTP->HTTPS handled by Ingress).
- Use read-only filesystem / runAsNonRoot for real apps (adjust Deployment specs).
- Rotate Cloudflare API token periodically.
- Consider SOPS + GitOps for secrets later.

## Roadmap / Next Steps

- Introduce Helm charts for apps.
- Add GitOps (Flux or Argo CD) to reconcile manifests automatically.
- Add metrics stack (kube-prometheus-stack) & centralized logging.
- Evaluate external-dns + wildcard cert.

## Migration Summary

Old: Terraform + Ansible -> Nginx vhosts + certbot  
New: Terraform + cloud-init -> k3s -> Ingress + cert-manager  
Rollback: Re-provision prior image and re-apply Ansible playbook (kept in repo) if necessary.

## Scalr Automation Workflow

Terraform in this repo is applied by Scalr automatically on pushes to `master` (and plans on PRs). Practical implications:

- Do NOT run `terraform apply` locally unless testing in an isolated workspace; it will diverge from Scalr state.
- k3s cloud-init runs only on first boot of a new server. Changing `user_data` on an existing server does NOT re-run it automatically.
- If you need to modify bootstrap behavior (e.g., enable Traefik), either:
  - Create a new server (taint or change name) so cloud-init re-executes, then cut DNS over, or
  - Manually apply changes (e.g., install ingress controller) via SSH/kubectl.

### Typical Flow After a Terraform Change

1. Push commit -> Scalr plan (if PR) or apply (if merged).
2. Wait for server creation (first provision) ~1–2 minutes. k3s installs automatically.
3. Run `scripts/k8s-bootstrap.sh <server-ip> <cloudflare-token> <email>` locally to seed cert-manager + apps.
4. Confirm Ingress & TLS: `kubectl get ingress -n web` and `kubectl describe certificate -n web multi-domain-tls`.

### Obtaining Server IP Programmatically

Scalr outputs can be mapped to Terraform outputs. The output `vps_ip` is defined in `terraform/outputs.tf`. Use Scalr UI or `scalr workspace output` (CLI) to retrieve it for scripting.

### Changing user_data Safely

Minor tweaks (e.g., extra packages) won’t retroactively apply. For idempotent post-config tasks consider:

- A follow-up systemd unit or Ansible *just for drift*, or
- Move complex logic into a repo-cloned bootstrap script executed via a oneshot systemd unit you can edit and re-run.

For now, keep cloud-init minimal and manage everything else declaratively in k8s.
