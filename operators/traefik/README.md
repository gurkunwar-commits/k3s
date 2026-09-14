# Traefik (bundled with k3s)

Tune the built-in Traefik chart and expose a TLS-protected dashboard.

## Setup steps

```bash
# 1. Enable dashboard API (pinned to control-plane)
kubectl apply -f manifests/01-helmchartconfig.yaml
kubectl -n kube-system rollout status deployment/traefik --timeout=5m

# 2. Create basic-auth secret (from head/.env TRAEFIK_DASH_*)
./setup-dashboard-auth.sh

# 3. Edit host in manifests/02-dashboard.yaml, then apply
kubectl apply -f manifests/02-dashboard.yaml

# 4. Verify
kubectl -n kube-system get ingressroute,certificate,middleware
```

## Notes

- Requires `operators/letsencrypt` first (ClusterIssuer for the Certificate).
- Dashboard URL: `https://<TRAEFIK_HOST>/dashboard/`
- Default: 1 replica on the control-plane so worker reboots do not take Ingress down.
