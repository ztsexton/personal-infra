# Personal Infrastructure - AI Agent Guidelines

## Architecture Overview

This is a **GitOps-driven personal infrastructure** hosting multiple domains on a single Hetzner VPS:
- **Terraform** provisions server + Cloudflare DNS (managed via Scalr CI/CD)
- **k3s** (lightweight Kubernetes) installed via cloud-init
- **Argo CD** (app-of-apps pattern) auto-syncs all manifests from `k8s/`
- **Traefik** ingress controller with **cert-manager** for Let's Encrypt DNS01 (Cloudflare)
- **1Password Operator** for native secrets management

### Key Domains
- zachsexton.com (+ subdomains: argocd, petfoodfinder, vigilo, spotifybutler)
- petfoodfinder.app
- vigilo.dev

## Critical Workflows

### 1. Never Run Terraform Locally
Scalr applies automatically on push to `master`. Local `terraform apply` causes state drift.

### 2. Bootstrap New Server
After Terraform provisions (first-time only):
```bash
./scripts/k8s-bootstrap.sh <server-ip> <cloudflare-token> <email>
```
This fetches kubeconfig, installs cert-manager, seeds Cloudflare secret.

### 3. Add New Application
1. Create manifests in `k8s/apps/<app-name>/` (deployment.yaml, service.yaml, ingress.yaml)
2. Set `namespace: web` in all manifests
3. Create `Certificate` in `k8s/cert-manager/certificates/<domain>.yaml` if new domain
4. Add DNS A record in `terraform/cloudflare.tf`
5. Commit → Scalr applies DNS → Argo CD syncs app

### 4. Debugging Argo CD
```bash
./scripts/diagnose_argo.sh  # Checks pods, CRDs, logs
kubectl get applications -n argocd
kubectl describe app <app-name> -n argocd
```

### 5. Access Cluster
```bash
ssh root@<server-ip> 'cat /root/.kube/config' > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get pods -A
```

## Project-Specific Conventions

### Namespace Strategy
- `web` → all public-facing apps (personal-site, petfoodfinder, vigilo, spotifybutler, mp3-helper)
- `argocd` → Argo CD + root Application manifests
- `traefik` → ingress controller
- `cert-manager` → certificate issuers + secrets
- `onepassword` → 1Password Connect + operator

### Argo CD Sync Waves
Control bootstrap order with `argocd.argoproj.io/sync-wave` annotation:
- `-2` → root Application (`k8s/argocd/root/root.yaml`)
- `-1` → Traefik ingress controller
- `0` → cert-manager
- `10+` → apps with external dependencies (e.g., External Secrets)

### Certificate Management
- **Per-domain approach**: Each domain gets its own `Certificate` CR (not multi-domain certs)
- Issuer: `cloudflare-dns` ClusterIssuer (DNS01 challenge)
- Secret naming: `<domain>-tls` (e.g., `zachsexton-com-tls`)
- Wildcard support: Create separate Certificate with `*.zachsexton.com` dnsName

### Terraform Secrets (via Scalr)
Required sensitive variables:
- `TF_VAR_k3s_token` → 64-char hex (`openssl rand -hex 32`)
- `TF_VAR_argocd_admin_password_bcrypt` → bcrypt hash (`htpasswd -nbBC 12 admin 'pass' | cut -d: -f2`)
- `TF_VAR_onepassword_connect_token` → 1Password Connect API token
- `TF_VAR_onepassword_credentials_json` → 1Password credentials JSON file content

### Ingress Pattern
All apps use standard Kubernetes Ingress (not Traefik CRDs):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app>
  namespace: web
spec:
  ingressClassName: traefik
  tls:
    - secretName: <domain>-tls
      hosts: [<domain>]
  rules:
    - host: <domain>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app>
                port:
                  number: 80
```

### Placeholder Apps
All apps in `k8s/apps/` currently use `hashicorp/http-echo:0.2.3` placeholder image with `-text` arg. Replace with real images when deploying production services.

## Integration Points

### 1Password Secrets Sync
- Operator automatically creates K8s secrets from `OnePasswordItem` CRs
- Bootstrap secrets (`onepassword-token`, `op-credentials`) created by Terraform during cloud-init
- See `k8s/onepassword/README.md` for OnePasswordItem examples

### Cloudflare DNS
- All A records point to single VPS IP (`hcloud_server.vps.ipv4_address`)
- `proxied = false` (DNS-only mode, not Cloudflare proxy)
- cert-manager uses Cloudflare API token for DNS01 challenge automation

### Traefik Configuration
- Helm chart deployed via Argo CD (`k8s/argocd/root/traefik.yaml`)
- `type: LoadBalancer` with static external IP (MetalLB)
- k3s bundled Traefik **disabled** via `disable_traefik = true` in Terraform

## Common Pitfalls

1. **cloud-init runs only once** → Changing `user_data` doesn't affect existing servers (taint/recreate required)
2. **Manual secret dependency** → Cloudflare API token must exist before cert-manager issues certificates
3. **Argo CD race conditions** → Use sync-waves to ensure infrastructure apps (Traefik, cert-manager) deploy before apps
4. **Certificate readiness** → Apps won't serve HTTPS until cert-manager solves DNS01 and creates TLS secret (check `kubectl get certificate -A`)
5. **SSH key file** → `mykey.ssh` in repo root is the automation SSH private key (keep `.gitignore`d)

## File Structure Patterns

```
terraform/          → Infrastructure (server, DNS); applied by Scalr
k8s/argocd/root/    → Argo CD Applications (app-of-apps sources)
k8s/apps/           → Per-app directories with deployment/service/ingress
k8s/cert-manager/   → ClusterIssuers + Certificate CRs
scripts/            → Bootstrap + diagnostic helpers
```

When editing manifests, preserve existing patterns (e.g., resource limits, readiness probes, sync-wave annotations).
