# k3s Platform

> Bootstrap a **3-node k3s cluster** (1 head + 2 workers) with Traefik, Let's Encrypt,
> Portainer, Longhorn, and CloudNativePG — Postgres HA with backups to **AWS S3**.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#)
[![k3s](https://img.shields.io/badge/k3s-stable-orange.svg)](https://k3s.io)
[![CNPG](https://img.shields.io/badge/CloudNativePG-HA-green.svg)](https://cloudnative-pg.io)

## What you get

| Component | Role |
|-----------|------|
| **k3s** | Lightweight Kubernetes (head + workers) |
| **Traefik** | Ingress + TLS dashboard |
| **cert-manager** | Let's Encrypt staging & prod issuers |
| **Portainer** | Cluster UI (**Tailscale-only**, not public) |
| **Tailscale** | Private MagicDNS Ingress for admin UIs |
| **Longhorn** | Replicated block storage |
| **CloudNativePG** | 3-instance Postgres + PgBouncer pooler |
| **AWS S3** | Barman base backups + WAL archive |

## Quick start

```bash
# 1. Head node
cd head && cp .env.example .env   # set IPs, domains, AWS keys, passwords
sudo ./boot.sh
# copy K3S_TOKEN into worker/.env

# 2. Each worker
cd worker && cp .env.example .env
sudo ./boot.sh

# 3. Platform (from a machine with kubectl)
cp deployment-setup/secrets/00-namespace-secrets.example.yaml \
   deployment-setup/secrets/00-namespace-secrets.yaml
# edit AWS + Postgres secrets
# set TS_CLIENT_ID / TS_CLIENT_SECRET in head/.env for private Portainer
./deployment-setup/install-platform.sh
# Portainer → https://portainer.<your-tailnet>.ts.net (Tailscale device required)

# 4. Postgres HA → AWS S3
# edit destinationPath in operators/cnpg/manifests/02-cnpg-cluster.yaml
kubectl apply -f operators/cnpg/manifests/02-cnpg-cluster.yaml

# 5. Demo app
sed "s/app.example.com/app.yourdomain.com/g" examples/example-web-app.yaml | kubectl apply -f -
```

## Repository layout

```text
k3s-platform/
├── head/                 # Control-plane boot + .env (secrets)
├── worker/               # Worker boot + .env (join token)
├── operators/
│   ├── cnpg/             # Postgres HA + AWS S3 backups
│   ├── letsencrypt/      # cert-manager ClusterIssuers
│   ├── traefik/          # Dashboard HelmChartConfig
│   ├── portainer/        # Portainer CE (Tailscale Ingress)
│   ├── tailscale/        # Tailscale k8s operator (private admin access)
│   └── longhorn/         # Storage + StorageClasses
├── deployment-setup/     # Namespaces, secrets, install-platform.sh
├── examples/             # Demo apps & DB connection pattern
└── docs/                 # Guides (namespaces, DNS/TLS, AWS S3, …)
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting started](docs/getting-started.md) | End-to-end install order |
| [Namespaces](docs/namespaces.md) | Sample namespaces & what belongs where |
| [AWS S3 backups](docs/aws-s3-backups.md) | Bucket, IAM, CNPG Barman |
| [DNS & TLS](docs/dns-and-tls.md) | Domains, Traefik, Let's Encrypt |
| [Portainer via Tailscale](docs/tailscale-portainer.md) | Private admin UI (no public Ingress) |
| [Deploy an app](docs/deploy-an-app.md) | Ingress + cert pattern |
| [Examples](examples/README.md) | Hello, web app, Postgres connection |

## Sample namespaces

```bash
kubectl get ns
```

| Namespace | Purpose |
|-----------|---------|
| `apps` | Production / staging application Deployments |
| `postgres` | CloudNativePG cluster, pooler, backups |
| `demo` | Throwaway smoke tests |
| `portainer` | Portainer CE |
| `cert-manager` | ACME certificates |
| `cnpg-system` | CNPG operator |
| `longhorn-system` | Longhorn engine / UI |
| `kube-system` | Traefik, CoreDNS, k3s internals |

See **[docs/namespaces.md](docs/namespaces.md)** for labels, RBAC tips, and a copy-paste sample.

## Architecture (high level)

```text
Internet                         Tailscale tailnet (admins only)
   │  :80 / :443                        │
   ▼                                    ▼
Traefik (control-plane)          Tailscale k8s operator
   ├─ Traefik dashboard                 │
   └─ Your apps (apps/)                 ▼
          │                      Portainer (ClusterIP)
          ▼                      https://portainer.<tailnet>.ts.net
   CloudNativePG (3 pods / 3 nodes)
          │  WAL + base backups
          ▼
      AWS S3 bucket
```

Portainer is **not** on Traefik/public DNS — see [docs/tailscale-portainer.md](docs/tailscale-portainer.md).

## Secrets

- Copy every `.env.example` → `.env` (gitignored).
- Copy `deployment-setup/secrets/*.example.yaml` → real secret YAML (gitignored).
- Never commit AWS keys or DB passwords.

## License

MIT — use and adapt for your clusters.
