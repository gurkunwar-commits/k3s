# Tailscale Kubernetes Operator

Exposes selected cluster services (e.g. Portainer) on your **private tailnet**
with MagicDNS + HTTPS. Nothing is published on the public internet.

## Why

Portainer has `cluster-admin` access. A public Traefik Ingress is a high-value
attack surface. Tailscale Ingress keeps it reachable only from devices logged
into your tailnet.

## Prerequisites

## Prerequisites (do these first)

Complete **all** of the following in the [Tailscale admin console](https://login.tailscale.com)
**before** installing the operator. Skipping any of them causes CrashLoopBackOff
or `Connection refused` on `:443`.

### 1. DNS + HTTPS (required for Ingress)

Admin → **[DNS](https://login.tailscale.com/admin/dns)**:

- [ ] **MagicDNS** enabled
- [ ] **HTTPS Certificates** enabled

Without HTTPS Certificates the operator warns `HTTPSNotEnabled` and
`curl https://…` fails with **connection refused** on port 443 (DNS/ACL can
still look fine).

### 2. ACL tags + access

Admin → **[Access controls](https://login.tailscale.com/admin/acls)** — merge into
your policy (do not wipe existing rules). Default operator tags:

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

Notes:

- Use **`autogroup:member`** (singular). Mixing with old `autogroup:members`
  makes the ACL editor reject the save.
- If your policy already uses the old plural form everywhere, use
  `autogroup:members` consistently instead — never both.
- Tighten `src` later (e.g. `group:sre`) once things work.

### 3. OAuth client

Admin → **[Settings → OAuth clients](https://login.tailscale.com/admin/settings/oauth)** → **Generate**:

| Setting | Value |
|---------|--------|
| Scopes | `devices:core`, `auth_keys` (**write**) |
| Tags the client may create | **`tag:k8s-operator`**, **`tag:k8s`** |

Missing tags → operator CrashLoopBackOff:

```text
creating operator authkey: requested tags [tag:k8s-operator] are invalid or not permitted (400)
```

Copy **Client ID** and **Client secret** (`tskey-client-…`).

### 4. Client devices

Laptop/admins run the Tailscale client, logged into the **same** tailnet, with
MagicDNS/Tailscale DNS active.

### 5. Credentials in `head/.env`

On the machine that runs the install script (usually the **head node**):

```bash
TS_CLIENT_ID=...CNTRL
TS_CLIENT_SECRET=tskey-client-...
TS_OPERATOR_HOSTNAME=k3s-tailscale-operator
PORTAINER_TS_HOSTNAME=portainer
INSTALL_TAILSCALE=true
```

Empty `TS_CLIENT_*` installs an operator that cannot authenticate.

## Install

Run the script from the repo root (do **not** paste the script into the shell
piecemeal — that often skips writing the OAuth values file):

```bash
# On the head node, from the k3s-platform repo
set -a; source head/.env; set +a
echo "ID len=${#TS_CLIENT_ID} SECRET len=${#TS_CLIENT_SECRET}"   # both > 0

chmod +x operators/tailscale/install-operator.sh
./operators/tailscale/install-operator.sh
```

The script adds the Helm repo, installs `tailscale/tailscale-operator` into
namespace `tailscale`, and waits for the rollout.

Verify:

```bash
kubectl -n tailscale get deploy,pods
# operator 1/1 Running

kubectl get ingressclass
# Expect: tailscale

# Admin → Machines: k3s-tailscale-operator (or TS_OPERATOR_HOSTNAME) Connected
```

## Expose Portainer (private)

```bash
kubectl apply -f operators/portainer/manifests/portainer.yaml
kubectl apply -f operators/portainer/manifests/ingress-tailscale.yaml

kubectl -n portainer get ingress portainer-tailscale -o wide
# ADDRESS should become: portainer.<tailnet>.ts.net

kubectl -n tailscale get pods
# Expect: operator + ts-portainer-tailscale-… Running
```

URL (Admin → DNS for your tailnet name, e.g. `taild44ea4.ts.net`):

```text
https://portainer.<your-tailnet>.ts.net
```

### First-login Portainer lockout

If nobody completes admin setup within Portainer’s security window, the UI
shows *timed out for security purposes* (and `/timeout.html`). Restart and
finish setup immediately:

```bash
kubectl -n portainer rollout restart deploy/portainer
kubectl -n portainer rollout status deploy/portainer --timeout=2m
kubectl -n portainer logs deploy/portainer --tail=40 | grep -A5 setup_token
```

Open the MagicDNS URL, paste `setup_token`, create the admin user **before**
the window expires again.

## Remove any old public Ingress

```bash
kubectl -n portainer delete ingress portainer portainer-public --ignore-not-found
# Also remove public DNS A record for portainer.example.com if it exists
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| CrashLoop: `requested tags [tag:k8s-operator] are invalid or not permitted` | Add `tagOwners` + grant those tags on the OAuth client; re-run `install-operator.sh` |
| CrashLoop / OAuth errors | `TS_CLIENT_ID` / `TS_CLIENT_SECRET` empty or wrong; check `kubectl -n tailscale logs deploy/operator` |
| Ingress event `HTTPSNotEnabled` / `:443` connection refused | Enable **HTTPS Certificates** (Admin → DNS); delete the `ts-portainer-*` pod to recreate the proxy |
| DNS resolves, ping works, browser fails | MagicDNS off on client; use full `*.ts.net` URL over HTTPS |
| ACL save error mixing `autogroup:member` / `members` | Use one style only (prefer `autogroup:member`) |
| `ProxyGroup "" does not exist` in operator logs | Harmless for default per-Ingress proxies; ignore if `ts-portainer-*` is Running |
| `kubectl … NotFound` on your laptop | Run cluster commands on the **head node** (or point `KUBECONFIG` at that cluster) |
| Portainer “timed out for security” | `kubectl -n portainer rollout restart deploy/portainer` + complete setup with `setup_token` |
| Traefik already on node `:443` | Unrelated to Tailscale `100.x:443`; do not disable Traefik for this |

Debug snippets (head node):

```bash
kubectl -n tailscale logs deploy/operator --tail=80
kubectl -n portainer describe ingress portainer-tailscale
kubectl -n tailscale get pods
kubectl -n tailscale logs "$(kubectl -n tailscale get pod -o name | grep portainer | head -1)" --tail=50
```

After enabling HTTPS mid-flight:

```bash
kubectl -n tailscale get pods | grep portainer
kubectl -n tailscale delete pod -l tailscale.com/parent-resource=portainer-tailscale
# or: kubectl -n tailscale delete pod ts-portainer-tailscale-<id>-0
```

From a Tailscale device:

```bash
tailscale status | grep -i portainer
curl -vkI https://portainer.<your-tailnet>.ts.net
```

Full walkthrough: [docs/tailscale-portainer.md](../../docs/tailscale-portainer.md)
