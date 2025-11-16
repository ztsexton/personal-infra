# MP3 Helper Application

Deployment configuration for the MP3 Helper application available at `zachsexton.com/mp3`.

## Source Code

Repository: <https://github.com/ztsexton/mp3-helper>

## Deployment

The application is automatically deployed via ArgoCD when changes are pushed to this repository.

## Setup Steps

1. **Add GitHub Actions workflow to mp3-helper repository**:
   - Copy the workflow from `github-workflow-example.yml` to `.github/workflows/docker-publish.yml` in the mp3-helper repo
   - This will automatically build and push Docker images to GitHub Container Registry

2. **Make the GitHub Package public** (if needed):
   - Go to <https://github.com/ztsexton/mp3-helper/pkgs/container/mp3-helper>
   - Click "Package settings"
   - Change visibility to "Public" (or configure image pull secrets for private images)

3. **Deploy**:

   ```bash
   git add .
   git commit -m "Add mp3-helper deployment"
   git push
   ```

## Configuration

- **Container Port**: 8080 (adjust in deployment.yaml if your app uses a different port)
- **Service Port**: 80
- **Path**: `/mp3`
- **Domain**: `zachsexton.com/mp3` and `www.zachsexton.com/mp3`

## Updating the Application

The deployment uses the `latest` tag. To update:

1. Push changes to the mp3-helper repository
2. GitHub Actions will build and push a new image with the `latest` tag
3. Restart the deployment to pull the new image:

   ```bash
   kubectl rollout restart deployment mp3-helper -n web
   ```

Or set up automatic image updates with ArgoCD Image Updater.
