# Portainer CE

Cluster UI pinned to the control-plane. **Default access is Tailscale-only** —
no public Traefik Ingress.

## Setup (private — recommended)

```bash
# 1. Tailscale operator (OAuth in head/.env)
./operators/tailscale/install-operator.sh

# 2. Portainer workload (ClusterIP only)
kubectl apply -f manifests/portainer.yaml

# 3. Private Ingress → https://portainer.<tailnet>.ts.net
kubectl apply -f manifests/ingress-tailscale.yaml

kubectl -n portainer get deploy,svc,ingress
```

Full guide: [docs/tailscale-portainer.md](../../docs/tailscale-portainer.md)

## Public Ingress (discouraged)

Only if you accept internet exposure:

```bash
sed "s/portainer.example.com/${PORTAINER_HOST}/g" \
  manifests/ingress-public.optional.yaml | kubectl apply -f -
```

Prefer deleting any public Ingress and DNS instead.

## Notes

- Uses `emptyDir` for demo simplicity; switch to a Longhorn PVC for persistence.
- ServiceAccounts are bound to `cluster-admin` — another reason to keep this off the public internet.
