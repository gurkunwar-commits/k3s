#!/usr/bin/env bash
#
# Deploy the Signal Board demo: a 3-tier app (nginx SPA -> PostgREST -> the HA
# Postgres cluster) exposed at a public host through Traefik + Let's Encrypt.
#
# Usage:
#   DOMAIN=stg01-k3s.example.com ./deploy.sh
#
# Prereqs: the platform is installed (Traefik, cert-manager, CNPG cluster
# `postgres-ha` in namespace `postgres`), a DNS A record for $DOMAIN points at
# the ingress, and kubectl targets the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${DOMAIN:?Set DOMAIN, e.g. DOMAIN=stg01-k3s.example.com ./deploy.sh}"
NS="${NS:-apps}"
PG_NS="${PG_NS:-postgres}"
PG_PRIMARY="${PG_PRIMARY:-postgres-ha-1}"
APP_DB="${APP_DB:-appdb}"

echo "==> Schema, roles and seed data in ${APP_DB}"
# Generate the authenticator password once; reuse it for the role and the URI.
AUTH_PW="$(openssl rand -hex 20)"
sed "s/AUTHPW_PLACEHOLDER/${AUTH_PW}/g" "${SCRIPT_DIR}/schema.sql" \
  | kubectl -n "${PG_NS}" exec -i "${PG_PRIMARY}" -c postgres -- \
      psql -U postgres -h /controller/run -d "${APP_DB}" -v ON_ERROR_STOP=1 -f -

echo "==> PostgREST DB secret"
URI="postgres://authenticator:${AUTH_PW}@postgres-ha-rw.${PG_NS}.svc:5432/${APP_DB}"
kubectl -n "${NS}" create secret generic postgrest-db \
  --from-literal=uri="${URI}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Frontend ConfigMap"
kubectl -n "${NS}" create configmap web-index \
  --from-file=index.html="${SCRIPT_DIR}/web/index.html" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> API + frontend workloads"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-postgrest.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/20-web.yaml"

echo "==> Ingress + TLS for ${DOMAIN}"
sed "s/__DOMAIN__/${DOMAIN}/g" "${SCRIPT_DIR}/manifests/30-ingress.yaml" | kubectl apply -f -

kubectl -n "${NS}" rollout status deploy/postgrest --timeout=3m
kubectl -n "${NS}" rollout status deploy/web --timeout=3m

echo
echo "Signal Board deployed. Once the certificate is issued:"
echo "  https://${DOMAIN}/"
echo "Watch the cert:  kubectl -n ${NS} get certificate web-tls -w"
