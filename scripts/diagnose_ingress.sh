#!/usr/bin/env bash
set -euo pipefail

# Simple k3s / Traefik / cert-manager ingress diagnostic helper.
# Usage: ./scripts/diagnose_ingress.sh [namespace(optional, default=web)]

NS=${1:-web}
YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

headline() { echo -e "\n${YELLOW}==> $1${NC}"; }
ok() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }
err() { echo -e "${RED}$1${NC}"; }

require() {
	if ! command -v "$1" >/dev/null 2>&1; then err "Missing required command: $1"; exit 1; fi
}

require kubectl

headline "Cluster core info"
kubectl version --short || true
kubectl get nodes -o wide || true

headline "Traefik deployment(s)"
kubectl get pods -A -l app=traefik || true
kubectl get svc -A | grep -i traefik || true

headline "IngressClasses"
kubectl get ingressclasses || true

headline "Ingresses in namespace $NS"
kubectl get ingress -n "$NS" -o wide || true

for ing in $(kubectl get ingress -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
	headline "Describe ingress $NS/$ing"
	kubectl describe ingress "$ing" -n "$NS" || true
done

headline "Services backing ingresses (namespace $NS)"
kubectl get svc -n "$NS" || true

headline "Endpoints (namespace $NS)"
kubectl get endpoints -n "$NS" || true

headline "Pods (namespace $NS)"
kubectl get pods -n "$NS" -o wide || true

headline "Recent Events (namespace $NS)"
kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -n 40 || true

headline "cert-manager Certificates (cluster)"
kubectl get certificate -A || true

headline "cert-manager CertificateRequests (recent)"
kubectl get certificaterequests.cert-manager.io -A | tail -n 20 || true

headline "cert-manager Challenges (pending)"
kubectl get challenges.acme.cert-manager.io -A || true

headline "Secrets referenced by ingresses (namespace $NS)"
for sec in $(kubectl get ingress -n "$NS" -o jsonpath='{.items[*].spec.tls[*].secretName}' 2>/dev/null | tr ' ' '\n' | sort -u); do
	echo "-- $sec"
	kubectl get secret "$sec" -n "$NS" -o jsonpath='Type: {.type}\nData Keys: {.data}' 2>/dev/null || true
	echo
done

headline "Traefik logs (last 200 lines)"
TRAEFIK_POD=$(kubectl get pods -A -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
TRAEFIK_NS=$(kubectl get pods -A -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo kube-system)
if [[ -n "$TRAEFIK_POD" ]]; then
	kubectl logs -n "$TRAEFIK_NS" "$TRAEFIK_POD" --tail=200 || true
else
	warn "Could not automatically find Traefik pod (label app.kubernetes.io/name=traefik)."
fi

headline "Common checks summary"

# Check if default ingress class is set
if kubectl get ingressclass traefik >/dev/null 2>&1; then
	if kubectl get ingressclass traefik -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -qi true; then
		ok "IngressClass 'traefik' marked as default"
	else
		warn "IngressClass 'traefik' not marked default (may be fine if explicit ingressClassName used)"
	fi
else
	warn "IngressClass 'traefik' not found"
fi

# Detect multiple Traefik installs (k3s default vs custom)
COUNT=$(kubectl get pods -A -l app=traefik 2>/dev/null | grep -v NAME | wc -l || echo 0)
if [[ "$COUNT" -gt 1 ]]; then
	warn "Multiple Traefik pods across namespaces -> ensure only desired controller is active."
fi

headline "Done"
