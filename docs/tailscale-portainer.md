# Portainer over Tailscale (recommended)

Keep Portainer **off the public internet**. Admins reach it only via your
Tailscale tailnet (MagicDNS + HTTPS issued by Tailscale).

Host Traefik on the node’s public `:443` does **not** conflict — Tailscale
Ingress listens on the Tailscale IP (`100.x`) only.

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

## Step 0 — Tailnet prerequisites (before install)

Do these in the admin console **first**. Skipping them is the usual cause of
CrashLoopBackOff or `Connection refused` on `:443`.

### DNS + HTTPS

[Admin → DNS](https://login.tailscale.com/admin/dns):

1. Enable **MagicDNS**
2. Enable **HTTPS Certificates**

Without HTTPS Certificates the Ingress emits `HTTPSNotEnabled` and nothing
listens on Tailscale `:443`.

### ACL tags + access

[Admin → Access controls](https://login.tailscale.com/admin/acls) — merge (keep
your other rules):

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:k8s:*"]
    }
  ]
}
```

Use **`autogroup:member`** (singular). Do not mix with legacy
`autogroup:members` in the same policy.

## Step 1 — OAuth client

1. Open [OAuth clients](https://login.tailscale.com/admin/settings/oauth)
2. **Generate OAuth client**
3. Scopes: `devices:core`, `auth_keys` → **Write**
4. Tags the client may create: **`tag:k8s-operator`**, **`tag:k8s`**
5. Copy **Client ID** and **Client secret** (`tskey-client-…`)

Missing tags → fatal log:

```text
requested tags [tag:k8s-operator] are invalid or not permitted (400)
```

Put credentials in `head/.env` on the **head node** (the host that runs the
install script):

```bash
TS_CLIENT_ID=k123456CNTRL
TS_CLIENT_SECRET=tskey-client-xxxxx-yyyyy
TS_OPERATOR_HOSTNAME=k3s-tailscale-operator
PORTAINER_TS_HOSTNAME=portainer
```

## Step 2 — Install the operator

Run the script (do **not** paste it piecemeal into bash — that often skips the
OAuth values file):

```bash
set -a; source head/.env; set +a
echo "ID len=${#TS_CLIENT_ID} SECRET len=${#TS_CLIENT_SECRET}"
chmod +x operators/tailscale/install-operator.sh
./operators/tailscale/install-operator.sh
```

Confirm in **Machines** that `k3s-tailscale-operator` (or your hostname) is
**Connected**.

```bash
kubectl -n tailscale get pods
kubectl get ingressclass
# Expect: operator 1/1 Running, IngressClass "tailscale"
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
kubectl apply -f operators/portainer/manifests/ingress-tailscale.yaml

kubectl -n portainer get ingress portainer-tailscale -o wide
kubectl -n portainer describe ingress portainer-tailscale
kubectl -n tailscale get pods   # operator + ts-portainer-tailscale-…
```

Wait until `ADDRESS` shows `portainer.<tailnet>.ts.net`. Find `<tailnet>` under
Admin → **DNS**.

From a device on the tailnet:

```text
https://portainer.<your-tailnet>.ts.net
```

```bash
curl -vkI https://portainer.<your-tailnet>.ts.net
```

### Complete Portainer admin setup immediately

Portainer locks itself if no admin is created within its security window
(*timed out for security purposes* / `/timeout.html`):

```bash
kubectl -n portainer rollout restart deploy/portainer
kubectl -n portainer logs deploy/portainer --tail=40 | grep -A5 setup_token
```

Open the URL, paste `setup_token`, create the admin user right away.

## Step 5 — Remove public exposure (if previously enabled)

```bash
kubectl -n portainer delete ingress portainer portainer-public --ignore-not-found
# Delete public DNS A/AAAA for portainer.* at your DNS provider
# Ensure cloud firewall does not publish :9000 NodePorts
```

## Admin device checklist

- [ ] Tailscale app installed and logged into the same tailnet
- [ ] MagicDNS enabled (Admin → DNS)
- [ ] **HTTPS Certificates** enabled (Admin → DNS)
- [ ] ACL `tagOwners` + `tag:k8s:*` accept for your users
- [ ] OAuth client has tags `tag:k8s-operator` and `tag:k8s`
- [ ] Browser resolves `*.ts.net` (Tailscale DNS on)
- [ ] Operator + `portainer` machines **Connected** in Admin → Machines
- [ ] Cluster commands run on the **head node** (or correct `KUBECONFIG`)

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Tags not permitted (400) | ACL `tagOwners` + OAuth client tag grants; reinstall operator |
| Empty / bad OAuth secret | Fill `TS_CLIENT_*` in `head/.env`; run `install-operator.sh` |
| `HTTPSNotEnabled` / `:443` refused | Enable HTTPS Certificates; delete `ts-portainer-*` pod |
| DNS does not resolve | Enable MagicDNS; use Tailscale DNS on the client |
| ACL mix of `member` / `members` | Use one autogroup style only |
| `ProxyGroup "" does not exist` | OK for default Ingress proxies if `ts-portainer-*` is Running |
| kubectl NotFound on laptop | SSH to head node; wrong cluster context |
| Portainer security timeout | Restart deploy; setup with `setup_token` quickly |
| Traefik on host `:443` | Unrelated to Tailscale `100.x:443` |
| 502 / connection reset | `kubectl -n portainer get endpoints portainer` — pods Ready? |
| Still reachable publicly | Delete Traefik Ingresses for Portainer |

After turning HTTPS on mid-install:

```bash
kubectl -n tailscale delete pod -l tailscale.com/parent-resource=portainer-tailscale
# or delete the ts-portainer-tailscale-*-0 pod by name
```

## Hardening extras

- Restrict `src` to `group:sre` (or similar) instead of `autogroup:member`
- Prefer Tailscale identity + a strong Portainer admin password on first login
- Operator README: [operators/tailscale/README.md](../operators/tailscale/README.md)
