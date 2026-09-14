#!/usr/bin/env bash
# Install Tailscale Kubernetes Operator (private service exposure)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEAD_ENV="${ROOT}/head/.env"

if [[ -f "$HEAD_ENV" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$HEAD_ENV"
  set +a
fi

: "${TS_CLIENT_ID:?Set TS_CLIENT_ID (Tailscale OAuth client id) in head/.env or the environment}"
: "${TS_CLIENT_SECRET:?Set TS_CLIENT_SECRET (Tailscale OAuth client secret) in head/.env or the environment}"

TS_OPERATOR_HOSTNAME="${TS_OPERATOR_HOSTNAME:-k3s-tailscale-operator}"
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"  # leave empty for https://controlplane.tailscale.com

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add tailscale https://pkgs.tailscale.com/helmcharts 2>/dev/null || true
helm repo update tailscale

# Pass the OAuth credentials through a mode-600 values file rather than
# --set on the command line, so the client secret never appears in the process
# list (`ps`) or shell history.
VALUES_FILE="$(mktemp)"
chmod 600 "$VALUES_FILE"
trap 'rm -f "$VALUES_FILE"' EXIT

{
  echo "oauth:"
  echo "  clientId: \"${TS_CLIENT_ID}\""
  echo "  clientSecret: \"${TS_CLIENT_SECRET}\""
  [[ -n "$TS_LOGIN_SERVER" ]] && echo "  loginServer: \"${TS_LOGIN_SERVER}\""
  echo "operatorConfig:"
  echo "  hostname: \"${TS_OPERATOR_HOSTNAME}\""
} >"$VALUES_FILE"

helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --create-namespace \
  --wait \
  --timeout 10m \
  --values "$VALUES_FILE"

kubectl -n tailscale rollout status deploy/operator --timeout=5m
kubectl get ingressclass tailscale

echo
echo "Tailscale operator ready."
echo "Next: kubectl apply -f ${ROOT}/operators/portainer/manifests/ingress-tailscale.yaml"
echo "Then open https://portainer.<your-tailnet>.ts.net from a Tailscale device."
