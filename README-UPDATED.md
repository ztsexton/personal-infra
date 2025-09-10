# Personal Infrastructure with k3s, ArgoCD, and Envoy

This repository contains a complete infrastructure-as-code setup for running a personal Kubernetes cluster with GitOps automation. The setup migrated from a complex Traefik-based configuration to a simplified k3s + ArgoCD + Envoy stack.

## Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Cloudflare    │    │   Hetzner VPS    │    │   GitHub Repo   │
│   DNS + Proxy   │───▶│  k3s + ArgoCD    │◀───│   GitOps Source │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Envoy Proxy     │
                    │  (Port 80/443)   │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Applications    │
                    │  personal-site   │
                    │  petfoodfinder   │
                    │  vigilo          │
                    │  spotifybutler   │
                    └──────────────────┘
```

## Technology Stack

### Core Infrastructure
- **k3s**: Lightweight Kubernetes distribution
- **ArgoCD**: GitOps continuous deployment
- **Envoy Proxy**: Layer 7 load balancer and ingress controller
- **cert-manager**: Automatic TLS certificate management
- **Terraform**: Infrastructure provisioning
- **Hetzner Cloud**: VPS hosting
- **Cloudflare**: DNS management and CDN

### Applications
- Personal website (`zachsexton.com`)
- ArgoCD UI (`argocd.zachsexton.com`)
- Pet Food Finder (`petfoodfinder.zachsexton.com`)
- Vigilo monitoring (`vigilo.zachsexton.com`)
- Spotify Butler (`spotifybutler.zachsexton.com`)

## Project History and Migration Journey

### Initial Problem
Started with a complex setup using Traefik that had reliability issues with ArgoCD, Helm, and certificate management. The user expressed: *"I'm tired of dealing with issues here with argo + helm + traefik. Let's update my setup to do a basic installation of k3s and argocd, and then let's use argocd to install envoy instead of traefik"*

### Migration Strategy
1. **Simplified Infrastructure**: Moved from complex Kubernetes to lightweight k3s
2. **GitOps First**: ArgoCD as the primary deployment mechanism
3. **Modern Ingress**: Replaced Traefik with Envoy for better reliability
4. **Infrastructure as Code**: Full Terraform automation for reproducibility

### Key Design Decisions

#### Why k3s over full Kubernetes?
- Simpler installation and maintenance
- Lower resource requirements
- Built-in components (no separate etcd, etc.)
- Perfect for single-node personal infrastructure

#### Why ArgoCD for GitOps?
- Declarative application management
- Git as single source of truth
- Automatic synchronization
- Web UI for monitoring deployments

#### Why Envoy over Traefik?
- More reliable configuration
- Better observability
- Industry-standard proxy
- Simpler debugging

## Directory Structure

```
personal-infra/
├── terraform/                 # Infrastructure provisioning
│   ├── hcloud.tf              # Hetzner Cloud VPS
│   ├── cloudflare.tf          # DNS records
│   ├── k3s.tf                 # ArgoCD installation automation
│   ├── templates/
│   │   └── cloud-init.yaml.tmpl # Server bootstrap script
│   └── terraform.tfvars       # Configuration variables
├── k8s/                       # Kubernetes manifests
│   ├── argocd/
│   │   └── root/              # Root ArgoCD applications
│   ├── envoy/                 # Envoy proxy configuration
│   ├── apps/                  # Application deployments
│   ├── cert-manager/          # TLS certificate management
│   └── namespaces/            # Namespace definitions
└── scripts/                   # Utility scripts
    ├── personal-web-server.sh # SSH helper
    └── diagnose_*.sh          # Troubleshooting scripts
```

## Key Components Deep Dive

### 1. Terraform Infrastructure

The Terraform configuration creates:
- Hetzner Cloud VPS with cloud-init bootstrap
- Cloudflare DNS records for all domains
- Automated ArgoCD installation via remote-exec

**Important Files:**
- `terraform/hcloud.tf`: VPS provisioning
- `terraform/cloudflare.tf`: DNS management  
- `terraform/k3s.tf`: Post-provisioning automation

### 2. k3s Installation

k3s is installed via cloud-init with Traefik disabled:
```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik
```

**Why disable Traefik?** We're using Envoy instead for ingress.

### 3. ArgoCD Setup

ArgoCD is installed using the official manifests:
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

The root application pattern is used for managing all other applications.

### 4. Envoy Configuration

Envoy is configured with:
- HTTP listener on port 80
- Host-based routing to different services
- Direct port binding using `hostNetwork: true`

## Deployment Process

### Initial Setup
1. Configure `terraform.tfvars` with your tokens
2. Run `terraform apply` to create infrastructure
3. ArgoCD automatically installs and syncs applications

### Application Updates
1. Modify Kubernetes manifests in `k8s/` directory
2. Commit and push to GitHub
3. ArgoCD automatically detects changes and deploys

### Infrastructure Updates
1. Modify Terraform configuration
2. Run `terraform plan` and `terraform apply`
3. For major changes, use `terraform destroy` and recreate

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. Envoy Pod CrashLoopBackOff

**Symptoms:**
```bash
$ kubectl get pods -n envoy-system
NAME                          READY   STATUS             RESTARTS   AGE
envoy-proxy-xxx               0/1     CrashLoopBackOff   3          2m
```

**Diagnosis:**
```bash
# Check pod logs
kubectl logs -n envoy-system envoy-proxy-xxx

# Common errors:
# - TLS certificate not found
# - Port binding conflicts
# - Configuration syntax errors
```

**Solutions:**
- **TLS Issues**: Remove HTTPS listener temporarily, fix cert-manager
- **Port Conflicts**: Ensure hostNetwork and correct port mapping
- **Config Errors**: Validate Envoy YAML syntax

**In our case:** TLS certificates weren't ready, so we temporarily removed HTTPS listener.

#### 2. cert-manager ClusterIssuer Not Ready

**Symptoms:**
```bash
$ kubectl get clusterissuer
NAME                     READY   AGE
cloudflare-dns           False   10m
```

**Diagnosis:**
```bash
# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check ClusterIssuer status
kubectl describe clusterissuer cloudflare-dns
```

**Common Issues:**
- Invalid email address (example.com domains not allowed)
- Missing Cloudflare API token secret
- Incorrect API token permissions

**Solution in our case:**
```bash
# The email was set to "you@example.com" 
# Need to update to real email in k8s/cert-manager/clusterissuer.yaml
```

#### 3. ArgoCD Applications Not Syncing

**Symptoms:**
```bash
$ kubectl get applications -n argocd
NAME           SYNC STATUS   HEALTH STATUS
envoy-proxy    OutOfSync     Degraded
```

**Diagnosis:**
```bash
# Check ArgoCD server logs
kubectl logs -n argocd deployment/argocd-server

# Check application details
kubectl describe application envoy-proxy -n argocd
```

**Common Solutions:**
- Verify Git repository access
- Check branch and path configuration
- Validate Kubernetes manifest syntax
- Force refresh: `kubectl patch application envoy-proxy -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge`

#### 4. DNS Resolution Issues

**Symptoms:**
- Domains not resolving to server IP
- Wrong IP returned by DNS queries

**Diagnosis:**
```bash
# Check DNS resolution
nslookup zachsexton.com
dig +short zachsexton.com

# Check Cloudflare DNS records
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
     "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records"
```

**Common Solutions:**
- Verify Cloudflare API token permissions
- Check Terraform DNS resource configuration
- Wait for DNS propagation (up to 24 hours)

#### 5. Application Connectivity Issues

**Symptoms:**
- 502 Bad Gateway responses
- Connection timeouts

**Diagnosis:**
```bash
# Test internal connectivity
kubectl exec -it envoy-proxy-xxx -n envoy-system -- curl http://personal-site.web.svc.cluster.local

# Check service endpoints
kubectl get endpoints -n web personal-site

# Check pod status
kubectl get pods -n web
```

**Common Solutions:**
- Verify service selector labels match pod labels
- Check pod readiness and health
- Validate cluster DNS (coredns)

### Useful Commands

#### Infrastructure Management
```bash
# Deploy infrastructure
terraform plan
terraform apply

# Destroy and recreate
terraform destroy
terraform apply

# Get server IP
terraform output vps_ip

# SSH to server
SSH_USER=root ./scripts/personal-web-server.sh "command"
```

#### Kubernetes Operations
```bash
# Check cluster status
kubectl get nodes
kubectl get pods --all-namespaces

# ArgoCD management
kubectl get applications -n argocd
kubectl describe application app-name -n argocd

# Force application sync
kubectl patch application app-name -n argocd -p '{"operation":{"sync":{}}}' --type=merge

# Check logs
kubectl logs -n namespace deployment/app-name
kubectl logs -n namespace pod-name

# Debug networking
kubectl get services -A
kubectl get endpoints -A
kubectl describe service service-name -n namespace
```

#### Envoy Debugging
```bash
# Check Envoy admin interface
kubectl port-forward -n envoy-system pod/envoy-proxy-xxx 9901:9901
curl http://localhost:9901/stats
curl http://localhost:9901/config_dump

# Test routing
curl -H "Host: zachsexton.com" http://server-ip/
curl -v http://zachsexton.com/
```

#### cert-manager Troubleshooting
```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate cert-name -n namespace

# Check ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer issuer-name

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

## Lessons Learned

### 1. Cloud-init vs Terraform remote-exec

**Initial Approach:** Complex cloud-init with ArgoCD installation
- Jobs would timeout or fail
- Difficult to debug
- No error handling

**Final Approach:** Simple cloud-init + Terraform remote-exec
- Reliable execution
- Better error messages
- Can retry failed steps

### 2. Provider Configuration Complexity

**Problem:** Dynamic kubeconfig in Terraform providers
- Circular dependencies
- Complex error messages
- Hard to troubleshoot

**Solution:** Separate infrastructure from application deployment
- Terraform for infrastructure only
- ArgoCD for application deployment
- Clear separation of concerns

### 3. Port Configuration with hostNetwork

**Problem:** Envoy hostNetwork requires matching containerPort and hostPort
```yaml
# WRONG - will fail
ports:
- containerPort: 8080
  hostPort: 80

# CORRECT - must match for hostNetwork
ports:
- containerPort: 80
  hostPort: 80
```

### 4. Certificate Management Dependencies

**Problem:** Applications requiring TLS before cert-manager is ready
- Chicken-and-egg problem
- CrashLoopBackOff cycles

**Solution:** Start with HTTP, add HTTPS later
- Deploy without TLS first
- Add HTTPS once certificates are working
- Progressive enhancement approach

### 5. GitOps Workflow Benefits

**Discovered:** ArgoCD makes infrastructure changes reliable
- Every change is tracked in Git
- Automatic synchronization works well
- Easy to rollback changes
- Clear audit trail

## Security Considerations

### Network Security
- UFW firewall configured for ports 22, 80, 443
- Cloudflare proxy for DDoS protection
- Private network communication within cluster

### Certificate Management
- Let's Encrypt certificates via cert-manager
- Automatic renewal
- DNS-01 challenge for wildcard certificates

### Access Control
- SSH key-based authentication
- ArgoCD RBAC (when properly configured)
- Kubernetes RBAC for service accounts

## Performance Optimization

### Resource Limits
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### Envoy Configuration
- Connection pooling
- Retry policies
- Circuit breakers
- Load balancing algorithms

## Monitoring and Observability

### Built-in Tools
- Envoy admin interface on port 9901
- ArgoCD UI for deployment status
- Kubernetes events and logs

### Key Metrics to Monitor
- Pod restart counts
- Certificate expiration dates
- DNS resolution times
- HTTP response codes
- Resource utilization

## Future Improvements

### Immediate Tasks
1. Fix cert-manager email configuration
2. Create Cloudflare API token secret
3. Re-enable HTTPS in Envoy
4. Add proper monitoring stack

### Long-term Enhancements
1. Implement Prometheus + Grafana monitoring
2. Add log aggregation (ELK stack)
3. Implement backup strategies
4. Add CI/CD for application builds
5. Implement proper secrets management (sealed-secrets or external-secrets)

## Configuration Files Reference

### Essential Environment Variables
```bash
# Terraform variables (terraform.tfvars)
hcloud_token = "your-hetzner-token"
cloudflare_api_token = "your-cloudflare-token"
cloudflare_zone_id = "your-zone-id"
ssh_private_key = file("~/.ssh/id_ed25519")

# Required secrets
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=your-token \
  -n cert-manager
```

### Important Commands for Daily Operations

```bash
# Check overall system health
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get applications -n argocd

# Deploy changes
git add -A && git commit -m "message" && git push

# Emergency debugging
SSH_USER=root ./scripts/personal-web-server.sh "kubectl get pods -A"
kubectl logs -n envoy-system deployment/envoy-proxy
curl -v http://zachsexton.com/

# Certificate troubleshooting
kubectl get certificates -A
kubectl describe clusterissuer cloudflare-dns
kubectl logs -n cert-manager deployment/cert-manager
```

This setup represents a modern, maintainable approach to personal infrastructure with proper GitOps practices, automated deployments, and clear troubleshooting procedures.
