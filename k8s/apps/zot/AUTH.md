# Zot Authentication Setup

## 1Password Configuration

Create a new item in 1Password with these details:

**Vault:** Kubernetes  
**Item Name:** zot-htpasswd  
**Type:** Password (or Secure Note)

### Fields Required:

- **htpasswd** (password field) - Contains the bcrypt htpasswd entry

### Generate htpasswd Entry

Run this command locally to generate the htpasswd entry:

```bash
htpasswd -nbB admin YOUR_PASSWORD
```

This will output something like:
```
admin:$2y$05$DId8ctttxzgbGIxft/l9k..FfnxCPxdCWROnf.3l/YB4Le5jr9QAO
```

Copy this entire line (including `admin:` prefix) into the **htpasswd** field in 1Password.

### Multiple Users

To add multiple users, generate separate entries and put them on separate lines:

```bash
htpasswd -nbB admin PASSWORD1
htpasswd -nbB user2 PASSWORD2
```

Result in 1Password htpasswd field:
```
admin:$2y$05$...
user2:$2y$05$...
```

## How it Works

1. The `OnePasswordItem` resource (`onepassword-secret.yaml`) tells the 1Password Operator to sync the item
2. The operator creates a Kubernetes secret named `zot-auth` in the `web` namespace
3. Zot mounts this secret and uses it for HTTP Basic Authentication
4. All UI and API access requires authentication

## Testing

After deployment:

```bash
# Should return 401 Unauthorized
curl https://zot.zachsexton.com/v2/

# Should return 200 OK with credentials
curl -u admin:YOUR_PASSWORD https://zot.zachsexton.com/v2/

# Docker login
docker login zot.zachsexton.com
```

## Updating Credentials

Simply update the htpasswd field in 1Password. The 1Password Operator will automatically sync the changes to Kubernetes within ~1-2 minutes, and Zot will pick up the new credentials on the next request.
