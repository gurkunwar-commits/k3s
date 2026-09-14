#!/usr/bin/env bash
# Create Traefik dashboard basic-auth secret from env or prompts
set -euo pipefail

TRAEFIK_DASH_USER="${TRAEFIK_DASH_USER:-admin}"
TRAEFIK_DASH_PASS="${TRAEFIK_DASH_PASS:-}"

if [[ -z "$TRAEFIK_DASH_PASS" ]]; then
  # shellcheck disable=SC1091
  if [[ -f "$(dirname "$0")/../../head/.env" ]]; then
    source "$(dirname "$0")/../../head/.env"
  fi
fi

: "${TRAEFIK_DASH_PASS:?Set TRAEFIK_DASH_PASS (or put it in head/.env)}"

if ! command -v htpasswd >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y apache2-utils
  else
    echo "htpasswd required (apache2-utils / httpd-tools)" >&2
    exit 1
  fi
fi

htpasswd -nb "$TRAEFIK_DASH_USER" "$TRAEFIK_DASH_PASS" | \
  kubectl create secret generic traefik-dashboard-auth \
  -n kube-system --from-file=users=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

echo "Secret kube-system/traefik-dashboard-auth applied."
