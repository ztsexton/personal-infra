# Personal Infrastructure

This repository contains Infrastructure as Code (IaC) for managing personal web infrastructure, including web servers, DNS, and deployment pipelines.

## Infrastructure Overview

- **Server**: Hetzner Cloud VPS (CPX21 - 3 AMD CPU, 4GB RAM, 80GB SSD)
- **DNS & CDN**: Cloudflare
- **Configuration Management**: Ansible
- **Infrastructure Provisioning**: Terraform
- **CI/CD**: GitHub Actions

## Terraform Usage

### Prerequisites

1. [Terraform](https://www.terraform.io/downloads.html)
2. Hetzner Cloud API token
3. Cloudflare API token
4. Scalr account configured

### Configuration

The infrastructure is managed using Terraform with state stored in Scalr. Key components:

- `terraform/terraform.tf`: Main configuration for Hetzner Cloud VPS
- `terraform/cloudflare.tf`: DNS configuration for domains
- `terraform/backend.tf`: Scalr backend configuration

### Resources Managed

#### Hetzner Cloud
- VPS instance (Ubuntu 24.04)
- SSH key management
- Network configuration

#### Cloudflare
- DNS records for domains:
  - zachsexton.com
  - petfoodfinder.app
- Proxy configuration
- SSL/TLS settings

## Ansible Configuration

### Directory Structure

```
ansible/
├── inventory/
│   └── hosts.ini           # Server inventory
└── personal-web-server/
    ├── group_vars/
    │   └── all.yml         # Common variables
    └── playbooks/
        └── site.yml        # Main playbook
```

### Virtual Hosts

Apache is configured to serve multiple domains:
- zachsexton.com
- petfoodfinder.app

### Running Manually

```bash
ansible-playbook -i ansible/inventory/hosts.ini ansible/personal-web-server/playbooks/site.yml
```

## Scalr Integration

Scalr is used as the Terraform backend to:
- Store and version Terraform state
- Manage infrastructure changes
- Provide a collaborative environment for infrastructure management

Configuration:
```hcl
terraform {
  backend "remote" {
    hostname     = "zsexton.scalr.io"
    organization = "production-personal-websites"
    workspaces {
      name = "personal-websites"
    }
  }
}
```

## GitHub Actions

Automated deployment pipeline for Apache configuration changes:

- Triggers:
  - Push to `master` branch (only `ansible/**` changes)
  - Manual workflow dispatch

Pipeline Steps:
1. Checkout code
2. Install Ansible
3. Configure SSH access
4. Run Ansible in check mode (dry run)
5. Apply configuration changes

### Required Secrets

- `SSH_PRIVATE_KEY`: SSH key for server access

## Security Notes

- All sensitive values are stored as secrets/variables in appropriate platforms
- Cloudflare proxying enabled for additional security
- SSH key-based authentication only
- Regular Ubuntu security updates

## Scripts

The `scripts/` directory contains utility scripts:
- `personal-web-server.sh`: Quick SSH access to the web server

## Getting Started

### Local Development

1. Clone this repository
2. Configure required secrets:
   - Hetzner Cloud API token
   - Cloudflare API token and zone IDs
   - SSH keys
3. For local Terraform runs (optional, as Scalr handles this automatically):
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```
4. For local Ansible runs (optional, as GitHub Actions handles this automatically):
   ```bash
   ansible-playbook -i ansible/inventory/hosts.ini ansible/personal-web-server/playbooks/site.yml
   ```

### Automated Workflows

#### Terraform Changes (via Scalr)
- Opening a Pull Request triggers a Scalr plan
- Merging to `master` or pushing directly to `master` triggers a Scalr apply
- Plans and applies can be monitored in the Scalr UI at `zsexton.scalr.io`

#### Ansible Changes (via GitHub Actions)
- Changes to files under `ansible/**` automatically trigger the configuration deployment
- The GitHub Action will:
  1. Run a dry-run (check mode) first
  2. Apply the changes if the dry-run succeeds
- Status can be monitored in the repository's Actions tab

### Recommended Workflow

1. Create a new branch for your changes
2. Make infrastructure changes in the `terraform/` directory and/or configuration changes in the `ansible/` directory
3. Open a Pull Request
4. Review the Scalr plan (for Terraform changes)
5. Merge to `master` once approved
6. Monitor the automated deployments
