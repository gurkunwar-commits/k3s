# Deployment setup (cluster config)

Baseline namespaces, AWS S3 / Postgres secret scaffolding, and platform installer.

## Contents

| Path | Purpose |
|------|---------|
| `namespaces/` | App namespaces (`apps`, `postgres`, `demo`, `portainer`) |
| `secrets/` | Postgres + **AWS S3** credential templates |
| `install-platform.sh` | Longhorn → cert-manager → Traefik → Portainer → CNPG operator |

## Setup

```bash
export KUBECONFIG=~/.kube/config
set -a; source head/.env; set +a

cp deployment-setup/secrets/00-namespace-secrets.example.yaml \
   deployment-setup/secrets/00-namespace-secrets.yaml
# edit Postgres passwords + AWS_ACCESS_KEY_ID / secret / region

./deployment-setup/install-platform.sh
```

## Namespaces created

| Namespace | Purpose |
|-----------|---------|
| `apps` | Your application workloads |
| `postgres` | CloudNativePG cluster + pooler |
| `demo` | Smoke-test / hello examples |
| `portainer` | Portainer CE |
| `cert-manager` | Let's Encrypt (via Helm) |
| `cnpg-system` | CNPG operator (via Helm) |
| `longhorn-system` | Longhorn (via Helm) |

## Secrets contract

| Secret | Keys | Used by |
|--------|------|---------|
| `postgres/postgres-app-secret` | `username`, `password` | CNPG app role |
| `postgres/postgres-superuser-secret` | `username`, `password` | CNPG superuser |
| `postgres/postgres-s3-credentials` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `AWS_REGION` | Barman → **AWS S3** |
| `kube-system/traefik-dashboard-auth` | htpasswd `users` | Traefik UI |

For production, swap plain Secrets for External Secrets / Sealed Secrets / SOPS while keeping the same names and keys.
