#!/usr/bin/env bash
# Apply namespaces + install Longhorn, cert-manager, Traefik, Portainer, CNPG operator
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEAD_ENV="${ROOT}/head/.env"

if [[ -f "$HEAD_ENV" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$HEAD_ENV"
  set +a
fi

ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
TRAEFIK_HOST="${TRAEFIK_HOST:-traefik.example.com}"
APP_HOST="${APP_HOST:-app.example.com}"
LONGHORN_HOST="${LONGHORN_HOST:-longhorn.example.com}"
PORTAINER_TS_HOSTNAME="${PORTAINER_TS_HOSTNAME:-portainer}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"

echo "==> Namespaces"
kubectl apply -f "${ROOT}/deployment-setup/namespaces/"

if [[ -f "${ROOT}/deployment-setup/secrets/00-namespace-secrets.yaml" ]]; then
  echo "==> Secrets (Postgres + AWS S3)"
  kubectl apply -f "${ROOT}/deployment-setup/secrets/00-namespace-secrets.yaml"
else
  echo "==> No secrets file yet — copy example and fill AWS keys:"
  echo "    cp ${ROOT}/deployment-setup/secrets/00-namespace-secrets.example.yaml \\"
  echo "       ${ROOT}/deployment-setup/secrets/00-namespace-secrets.yaml"
fi

echo "==> NetworkPolicies (namespace isolation)"
kubectl apply -f "${ROOT}/deployment-setup/security/"

echo "==> Longhorn"
"${ROOT}/operators/longhorn/install.sh"

echo "==> Let's Encrypt / cert-manager"
ACME_EMAIL="$ACME_EMAIL" "${ROOT}/operators/letsencrypt/install.sh"

echo "==> Traefik config"
kubectl apply -f "${ROOT}/operators/traefik/manifests/01-helmchartconfig.yaml"
sleep 15
kubectl -n kube-system rollout status deployment/traefik --timeout=5m || true

if [[ -n "${TRAEFIK_DASH_PASS:-}" ]]; then
  TRAEFIK_DASH_USER="${TRAEFIK_DASH_USER:-admin}" \
    TRAEFIK_DASH_PASS="$TRAEFIK_DASH_PASS" \
    "${ROOT}/operators/traefik/setup-dashboard-auth.sh"
fi

sed "s/traefik.example.com/${TRAEFIK_HOST}/g" \
  "${ROOT}/operators/traefik/manifests/02-dashboard.yaml" | kubectl apply -f -

echo "==> Portainer (ClusterIP only — no public Ingress)"
kubectl apply -f "${ROOT}/operators/portainer/manifests/portainer.yaml"
# Drop legacy public Ingress if present from older installs
kubectl -n portainer delete ingress portainer portainer-public --ignore-not-found

if [[ "$INSTALL_TAILSCALE" == "true" ]]; then
  if [[ -n "${TS_CLIENT_ID:-}" && -n "${TS_CLIENT_SECRET:-}" ]]; then
    echo "==> Tailscale operator + private Portainer Ingress"
    "${ROOT}/operators/tailscale/install-operator.sh"
    sed "s/- portainer$/- ${PORTAINER_TS_HOSTNAME}/" \
      "${ROOT}/operators/portainer/manifests/ingress-tailscale.yaml" | kubectl apply -f -
  else
    echo "==> Skipping Tailscale (set TS_CLIENT_ID + TS_CLIENT_SECRET in head/.env)"
    echo "    Then: ./operators/tailscale/install-operator.sh"
    echo "          kubectl apply -f operators/portainer/manifests/ingress-tailscale.yaml"
  fi
fi

echo "==> CNPG operator"
"${ROOT}/operators/cnpg/install-operator.sh"

echo "==> Platform summary"
kubectl get nodes -o wide
kubectl get ns
kubectl get clusterissuer
kubectl get storageclass
kubectl -n cnpg-system get deploy
kubectl -n portainer get deploy,svc,ingress
kubectl get ingressclass 2>/dev/null || true
echo "-- NetworkPolicies --"
kubectl get networkpolicy -A 2>/dev/null || true
echo
echo "Portainer: Tailscale-only (https://${PORTAINER_TS_HOSTNAME}.<tailnet>.ts.net)"
echo "Do NOT apply operators/portainer/manifests/ingress-public.optional.yaml unless you accept public exposure."
echo
echo "Next:"
echo "  1. Set AWS bucket path in operators/cnpg/manifests/02-cnpg-cluster.yaml"
echo "  2. kubectl apply -f ${ROOT}/operators/cnpg/manifests/02-cnpg-cluster.yaml"
echo "  3. sed \"s/app.example.com/\${APP_HOST}/g\" ${ROOT}/examples/example-web-app.yaml | kubectl apply -f -"
echo "Optional Longhorn UI:"
echo "  sed \"s/longhorn.example.com/\${LONGHORN_HOST}/g\" ${ROOT}/operators/longhorn/manifests/ui-ingress.yaml | kubectl apply -f -"
