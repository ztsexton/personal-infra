#!/usr/bin/env bash
set -euo pipefail

echo '=== Argo CD Bootstrap Diagnostic ==='

echo '[1] Namespace:'
kubectl get ns argocd 2>/dev/null || echo 'argocd namespace missing'

echo '[2] Pods:'
kubectl get pods -n argocd 2>/dev/null || true

echo '[3] CRDs:'
kubectl get crd applications.argoproj.io 2>/dev/null || echo 'Application CRD missing'

echo '[4] HelmChart objects (kube-system namespace):'
kubectl get helmchart -n kube-system 2>/dev/null | grep -i argo || echo 'No argo-cd HelmChart found'

echo '[5] Bootstrap logs (journalctl tag bootstrap last 40 lines):'
journalctl -t bootstrap -n 40 --no-pager 2>/dev/null || true

echo '[6] Application list (if CRD present):'
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  kubectl get applications -n argocd || true
fi

echo '[7] Root Application manifest (if exists):'
kubectl get app root -n argocd -o yaml 2>/dev/null | sed -n '1,120p' || echo 'root Application not found'

echo '[8] Repo-server / controller logs (tail if pods exist):'
if kubectl get pods -n argocd 2>/dev/null | grep -q 'repo-server'; then
  kubectl logs -n argocd deploy/argo-cd-argocd-repo-server --tail=25 2>/dev/null || true
fi
if kubectl get pods -n argocd 2>/dev/null | grep -q 'application-controller'; then
  kubectl logs -n argocd deploy/argo-cd-argocd-application-controller --tail=25 2>/dev/null || true
fi

echo '[9] Next Steps Guidance:'
echo ' - If namespace missing AND no HelmChart: cloud-init did not seed resources; re-check user_data or apply HelmChart manually.'
echo ' - If HelmChart exists but no pods: check k3s logs: journalctl -u k3s -n 100.'
echo ' - If pods exist but no Applications: root Application race; apply k8s/argocd/root/apps.yaml manually.'
echo ' - If Applications exist but Traefik missing: describe the traefik app: kubectl describe app traefik -n argocd.'

echo '=== End Diagnostic ==='