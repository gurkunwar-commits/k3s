#!/usr/bin/env bash
# Install Longhorn + StorageClasses for Postgres / general workloads
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update longhorn

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set persistence.defaultClassReplicaCount=2 \
  --set defaultSettings.defaultReplicaCount=2 \
  --set defaultSettings.replicaSoftAntiAffinity=false \
  --set defaultSettings.storageMinimalAvailablePercentage=10 \
  --wait --timeout 15m

kubectl apply -f "${SCRIPT_DIR}/manifests/storageclasses.yaml"

# k3s ships local-path as a default StorageClass and Longhorn adds its own.
# Two defaults make PVC placement non-deterministic, so demote local-path and
# leave "longhorn" as the single cluster default.
if kubectl get storageclass local-path >/dev/null 2>&1; then
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
    >/dev/null 2>&1 || true
fi

echo "Longhorn ready."
kubectl get storageclass
