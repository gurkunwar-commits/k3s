# Tailscale Kubernetes Operator

Exposes selected cluster services (e.g. Portainer) on your **private tailnet**
with MagicDNS + HTTPS. Nothing is published on the public internet.

## Why

Portainer has `cluster-admin` access. A public Traefik Ingress is a high-value
attack surface. Tailscale Ingress keeps it reachable only from devices logged
into your tailnet.

## Prerequisites

1. [Tailscale account](https://login.tailscale.com) and admin access
2. OAuth client with scopes:
   - `devices:core`
   - `auth_keys` (write)
3. Create client: Admin console → **Settings** → **OAuth clients** → **Generate**
4. Your laptop (and admins) already run the Tailscale client and are online

## Install

```bash
# From repo root — values from head/.env
set -a; source head/.env; set +a

export TS_CLIENT_ID='...'          # or set in head/.env
export TS_CLIENT_SECRET='tskey-client-...'

./operators/tailscale/install-operator.sh
```

Verify:

```bash
kubectl -n tailscale get deploy,pods
kubectl get ingressclass
# Expect: tailscale
```

## Expose Portainer (private)

```bash
# Deploy Portainer without public Ingress (default manifests)
kubectl apply -f operators/portainer/manifests/portainer.yaml

# Tailscale Ingress → https://portainer.<tailnet>.ts.net
kubectl apply -f operators/portainer/manifests/ingress-tailscale.yaml

kubectl -n portainer get ingress portainer-tailscale -o wide
```

Open the MagicDNS URL from any device on the tailnet (browser must use Tailscale DNS).

Full walkthrough: [docs/tailscale-portainer.md](../../docs/tailscale-portainer.md)

## Remove any old public Ingress

```bash
kubectl -n portainer delete ingress portainer portainer-public --ignore-not-found
# Also remove public DNS A record for portainer.example.com if it exists
```
