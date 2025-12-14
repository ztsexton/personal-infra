# Ballroom Competition Web App

Accessible at: **https://zachsexton.com/ballroomcomp**

## Overview

This app pulls from the private Zot registry and is served at the `/ballroomcomp` path on zachsexton.com.

## Setup

### 1. Set up Docker Registry Credentials

Run the helper script to generate the credentials:

```bash
./scripts/setup-zot-registry-credentials.sh
```

This will generate a `.dockerconfigjson` that you need to add to 1Password.

### 2. Create 1Password Item

1. Go to 1Password → Kubernetes vault
2. Create new item: **zot-docker-config**
3. Add field named `.dockerconfigjson` (text type)
4. Paste the JSON from the script output
5. Save

### 3. Apply OnePasswordItem

```bash
kubectl apply -f k8s/apps/ballroom-competition-web/onepassword-secret.yaml
```

Wait 1-2 minutes for sync, then verify:

```bash
kubectl get secret zot-registry-credentials -n web
```

### 4. Deploy the App

The app will deploy automatically via Argo CD when you push to Git:

```bash
git add k8s/apps/ballroom-competition-web/
git commit -m "Add ballroom-competition-web app"
git push origin master
```

## Building and Pushing Images

To build and push a new version of your app to the Zot registry:

```bash
# Build the image
docker build -t zot.zachsexton.com/ballroom-competition-web:latest .

# Login to Zot
docker login zot.zachsexton.com
# Username: admin
# Password: (your password)

# Push the image
docker push zot.zachsexton.com/ballroom-competition-web:latest
```

Or use the GitHub Actions workflow from `k8s/apps/zot/example-github-action.yml`.

## Updating the App

To trigger a new deployment after pushing a new image:

```bash
# Restart the deployment to pull the latest image
kubectl rollout restart deployment/ballroom-competition-web -n web
```

Or update the image tag in `deployment.yaml` to use a specific version instead of `latest`.

## Configuration

- **Path**: `/ballroomcomp` (strip prefix middleware applied)
- **Image**: `zot.zachsexton.com/ballroom-competition-web:latest`
- **Namespace**: `web`
- **TLS**: Uses zachsexton-wildcard-tls certificate
- **Resources**: 128Mi-256Mi memory, 100m-500m CPU

## Troubleshooting

### Image pull errors

Check if the secret exists:
```bash
kubectl get secret zot-registry-credentials -n web -o yaml
```

Check pod events:
```bash
kubectl describe pod -n web -l app=ballroom-competition-web
```

### App not accessible

Check ingress:
```bash
kubectl get ingress personal-site-ingress -n web
kubectl describe ingress personal-site-ingress -n web
```

Check service and pods:
```bash
kubectl get svc,pods -n web -l app=ballroom-competition-web
```

Check logs:
```bash
kubectl logs -n web -l app=ballroom-competition-web
```
