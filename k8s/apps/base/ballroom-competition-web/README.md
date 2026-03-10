# Ballroom Competition Web App

Accessible at: **[https://petfoodfinder.app](https://petfoodfinder.app)**

## Overview

This app pulls from the private Zot registry and is served at the root of petfoodfinder.app.

## Setup

### 1. Docker Registry Credentials (Already Done!)

The `zot-registry-credentials` secret has been created using your existing Zot admin credentials. No additional setup needed!

To recreate if needed:

```bash
./scripts/personal-web-server.sh "ZOT_PASSWORD=\$(kubectl get secret zot-auth -n web -o jsonpath='{.data.password}' | base64 -d | cut -d: -f2) && kubectl create secret docker-registry zot-registry-credentials --docker-server=zot.zachsexton.com --docker-username=admin --docker-password=\"\$ZOT_PASSWORD\" -n web --dry-run=client -o yaml | kubectl apply -f -"
```

### 2. Deploy the App

The app will deploy automatically via Argo CD when you push to Git:

```bash
git add k8s/apps/ballroom-competition-web/
git commit -m "Add ballroom-competition-web app"
git push origin master
```

### 3. Firebase / Vite Config (1Password)

This deployment loads Firebase config from a Kubernetes Secret synced by the 1Password Operator.

- Kubernetes secret name: `ballroom-competition-web-firebase`
- Source 1Password item path: `vaults/Kubernetes/items/ballroom-competition-web-firebase`

Create a 1Password item with fields matching these environment variable names:

- `VITE_FIREBASE_API_KEY`
- `VITE_FIREBASE_AUTH_DOMAIN`
- `VITE_FIREBASE_PROJECT_ID`
- `VITE_FIREBASE_STORAGE_BUCKET`
- `VITE_FIREBASE_MESSAGING_SENDER_ID`
- `VITE_FIREBASE_APP_ID`

After the operator syncs, bump the `kubectl.kubernetes.io/restartedAt` annotation (or restart the
deployment) so the pod picks up the new env vars.

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

If you want to do this via Argo CD / GitOps (without running `kubectl`), bump the
pod template annotation in `k8s/apps/ballroom-competition-web/deployment.yaml`:

- `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt`

Any change to that value creates a new ReplicaSet, and because `imagePullPolicy: Always`
is set, the new pod will pull the updated `:latest` image.

Or update the image tag in `deployment.yaml` to use a specific version instead of `latest`.

## Configuration

- **Path**: `/` (root)
- **Image**: `zot.zachsexton.com/ballroom-competition-web:latest`
- **Namespace**: `web`
- **TLS**: Uses petfoodfinder-app-tls certificate
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
