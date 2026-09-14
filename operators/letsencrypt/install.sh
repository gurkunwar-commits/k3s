#!/usr/bin/env bash
# Install cert-manager and (optionally) apply ClusterIssuers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true

kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=5m

if [[ "${APPLY_ISSUERS:-true}" == "true" ]]; then
  sed "s/admin@example.com/${ACME_EMAIL}/g" \
    "${SCRIPT_DIR}/manifests/cluster-issuers.yaml" | kubectl apply -f -
  kubectl get clusterissuer
fi

echo "cert-manager / Let's Encrypt ready."
