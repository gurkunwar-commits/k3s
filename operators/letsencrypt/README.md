# Let's Encrypt via cert-manager

HTTP-01 ClusterIssuers for Traefik Ingress.

## Setup steps

```bash
# 1. Install cert-manager
./install.sh

# 2. Edit email in manifests/cluster-issuers.yaml (or sed from ACME_EMAIL)
# 3. Apply issuers
kubectl apply -f manifests/cluster-issuers.yaml

# 4. Verify
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-staging
```

## Usage on Ingress

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging   # or letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["app.example.com"]
      secretName: app-tls
```

Start with **staging** to avoid Let's Encrypt rate limits, then switch to **prod**.
