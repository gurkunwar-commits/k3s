# DNS and TLS

## Traffic flow

```text
Browser → https://app.example.com
       → DNS A → HEAD_PUBLIC_IP
       → Traefik (:443)
       → Ingress (apps namespace)
       → Service → Pods
```

TLS certificates are issued by **cert-manager** using Let's Encrypt **HTTP-01**
(solver class: `traefik`).

## DNS records

Point these A records at the **head public IP** (or your load balancer):

| Host (from `head/.env`) | Example | Used by |
|-------------------------|---------|---------|
| `API_HOST` | `api.example.com` | kubectl / k3s API SAN |
| `APP_HOST` | `app.example.com` | Example web app |
| `TRAEFIK_HOST` | `traefik.example.com` | Traefik dashboard |
| `LONGHORN_HOST` | `longhorn.example.com` | Optional Longhorn UI |

**Portainer** is not listed here on purpose — it is exposed only via Tailscale
MagicDNS (`https://portainer.<tailnet>.ts.net`). See [tailscale-portainer.md](tailscale-portainer.md).
Do not create a public `portainer.*` A record.

```bash
dig +short app.example.com
# should print HEAD_PUBLIC_IP
```

**Cloudflare:** use DNS-only (grey cloud) while testing HTTP-01.

## Firewall

Allow on the head (and any node Traefik binds to):

| Port | Purpose |
|------|---------|
| 80 | ACME HTTP-01 + redirect |
| 443 | HTTPS |
| 6443 | Kubernetes API (restrict by IP if possible) |
| SSH | Your admin IP only |

## Issuers

```bash
# Installed by operators/letsencrypt
kubectl get clusterissuer
# letsencrypt-staging
# letsencrypt-prod
```

Use **staging** until certificates work, then switch Ingress annotations to
`letsencrypt-prod` to avoid rate limits.

## App Ingress pattern

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["app.example.com"]
      secretName: app-tls
```

## Debug certificates

```bash
kubectl get certificate,certificaterequest,order,challenge -A
kubectl -n apps describe certificate example-web-tls
kubectl -n cert-manager logs deploy/cert-manager -c cert-manager --tail=100
```
