# Portainer over Tailscale (recommended)

Keep Portainer **off the public internet**. Admins reach it only via your
Tailscale tailnet (MagicDNS + HTTPS issued by Tailscale).

## Architecture

```text
Admin laptop (Tailscale client)
        │  WireGuard / Magicsock
        ▼
  Tailscale tailnet
        │
        ▼
Tailscale k8s operator (ns: tailscale)
        │  IngressClass: tailscale
        ▼
Ingress portainer-tailscale  →  Service portainer:9000  →  Portainer pod
        │
        ✗  No Traefik public Ingress
        ✗  No DNS A record on the open internet
```

URL shape: `https://portainer.<tailnet-name>.ts.net`

## Step 1 — OAuth client

1. Open [Tailscale admin console](https://login.tailscale.com/admin/settings/oauth)
2. **Generate OAuth client**
3. Scopes (minimum):
   - `devices:core`
   - `auth_keys` → **Write**
4. Copy **Client ID** and **Client secret** (`tskey-client-…`)

Put them in `head/.env`:

```bash
TS_CLIENT_ID=k123456CNTRL
TS_CLIENT_SECRET=tskey-client-xxxxx-yyyyy
TS_OPERATOR_HOSTNAME=k3s-tailscale-operator
# Optional rename of the MagicDNS label (default: portainer)
PORTAINER_TS_HOSTNAME=portainer
```

## Step 2 — Install the operator

```bash
set -a; source head/.env; set +a
chmod +x operators/tailscale/install-operator.sh
./operators/tailscale/install-operator.sh
```

Confirm in the Tailscale admin **Machines** list that `k3s-tailscale-operator`
(or your hostname) appears and is connected.

```bash
kubectl -n tailscale get pods
kubectl get ingressclass
```

## Step 3 — Deploy Portainer (ClusterIP only)

```bash
kubectl apply -f deployment-setup/namespaces/00-namespaces.yaml
kubectl apply -f operators/portainer/manifests/portainer.yaml
kubectl -n portainer rollout status deploy/portainer --timeout=3m
```

Do **not** apply `ingress-public.optional.yaml`.

## Step 4 — Tailscale Ingress

```bash
# Optional: rename MagicDNS label
# sed "s/portainer/${PORTAINER_TS_HOSTNAME}/g" ...
kubectl apply -f operators/portainer/manifests/ingress-tailscale.yaml

kubectl -n portainer describe ingress portainer-tailscale
```

Wait until the Ingress shows an address / hostname. Then from a device on the
tailnet:

```text
https://portainer.<your-tailnet>.ts.net
```

Find `<your-tailnet>` under Tailscale admin → **DNS** (e.g. `tail12345.ts.net`).

## Step 5 — Remove public exposure (if previously enabled)

```bash
kubectl -n portainer delete ingress portainer portainer-public --ignore-not-found
# Delete public DNS A/AAAA for portainer.* at your DNS provider
# Ensure cloud firewall does not publish :9000 NodePorts
```

## Admin device checklist

- [ ] Tailscale app installed and logged into the same tailnet  
- [ ] MagicDNS enabled (Admin → DNS)  
- [ ] Browser resolves `*.ts.net` (split DNS / MagicDNS on)  
- [ ] You can ping the operator machine in the admin UI  

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Ingress never gets an address | `kubectl -n tailscale logs deploy/operator` — OAuth scopes / secret |
| DNS does not resolve | Enable MagicDNS; use Tailscale DNS on the client |
| TLS warning | Wait for Tailscale cert provisioning; retry in a minute |
| 502 / connection reset | `kubectl -n portainer get endpoints portainer` — pods Ready? |
| Still reachable publicly | `kubectl -n portainer get ingress` — delete Traefik Ingresses |

## Hardening extras

- Restrict which Tailscale users/groups can reach tagged devices (ACL in Tailscale policy file)
- Tag the operator / Portainer proxy with something like `tag:k8s-admin` and allow only `group:sre`
- Prefer Tailscale **auth** + Portainer local admin password (still set a strong Portainer admin password on first login)

Example ACL snippet (Tailscale policy):

```json
{
  "tagOwners": {
    "tag:k8s-admin": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["group:sre"],
      "dst": ["tag:k8s-admin:*"]
    }
  ]
}
```

(Exact tags depend on how you configure `operatorConfig.defaultTags` / ProxyGroup; start with default operator install, then tighten.)
