# 1Password Operator Integration

This directory contains the configuration for the native 1Password Kubernetes operator, which syncs secrets from 1Password vaults directly into Kubernetes secrets using a GitOps approach.

## Architecture

- **1Password Connect**: Provides API access to 1Password vaults
- **1Password Operator**: Native Kubernetes operator for syncing secrets
- **GitOps**: All configuration is stored in Git and managed by ArgoCD

## Prerequisites

1. **1Password Business Account** with Connect integration enabled
2. **1Password Vault** dedicated to Kubernetes secrets (recommended)
3. **Terraform Variables**: Connect token and credentials configured in Scalr

## Setup Process

### Terraform + Scalr Automation

The bootstrap secrets are automatically created by Terraform:

1. **Create 1Password Connect Integration**:
   - Go to <https://my.1password.com/integrations/active>
   - Create a new "1Password Connect" integration
   - Download the `1password-credentials.json` file
   - Generate a Connect token

2. **Configure Scalr**:
   Set both Terraform variables as sensitive environment variables in Scalr:

   ```bash
   TF_VAR_onepassword_connect_token = "your-1password-connect-token-here"
   TF_VAR_onepassword_credentials_json = "paste-your-credentials-json-here"
   ```

3. **Deploy via Scalr**:
   Run `terraform apply` through Scalr - both required secrets will be created automatically during k3s setup

## How It Works

1. **Terraform Bootstrap**: Creates the required `onepassword-token` and `op-credentials` secrets
2. **1Password Connect**: Uses the credentials to provide API access to your vaults
3. **1Password Operator**: Watches for `OnePasswordItem` resources and syncs secrets
4. **Application Secrets**: Automatically created and updated from 1Password items

## Usage

Create `OnePasswordItem` resources to sync secrets from 1Password:

```yaml
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  itemPath: "vaults/Kubernetes/items/my-app-credentials"
  # Optional: sync only specific field
  secretKey: "password"
```

The operator will automatically create a Kubernetes secret with the same name containing the 1Password item data.

## Benefits of This Approach

- ✅ **GitOps Compliant**: All configuration in Git
- ✅ **Native Integration**: Purpose-built for 1Password
- ✅ **Automatic Sync**: Secrets update when changed in 1Password  
- ✅ **Simple Setup**: Direct path from 1Password to Kubernetes
- ✅ **Minimal Dependencies**: No additional operators needed
- ✅ **Terraform Automated**: Zero manual steps after Scalr configuration
