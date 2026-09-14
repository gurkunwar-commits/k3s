#!/usr/bin/env bash
# Install CloudNativePG operator via Helm
set -euo pipefail

helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace

kubectl -n cnpg-system rollout status deployment/cnpg-cloudnative-pg --timeout=5m
kubectl get crd | grep postgresql.cnpg.io || true
echo "CNPG operator ready."
