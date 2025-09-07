# Argo CD Root (App-of-Apps)

This directory is the source for the bootstrap **root Application** created automatically by cloud-init on the k3s server.

Add one `Application` manifest per logical stack (infra, apps, cert-manager, ingress, etc.) OR use subfolders (e.g. `infrastructure/`, `apps/`) and an ApplicationSet later.

Example minimal child Application (save as `apps.yaml` or split files):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/ztsexton/personal-infra.git
    path: k8s/apps
    targetRevision: HEAD
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Add additional Application manifests for:
- cert-manager (CRDs should be installed via its own HelmChart or pre-seeded; until then you can keep manual install)
- ingress / shared resources
- namespaces (or rely on CreateNamespace=true)

Commit changes; Argo CD root app will detect and sync automatically.
