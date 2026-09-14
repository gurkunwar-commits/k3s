# Longhorn

Replicated block storage used by CloudNativePG volumes.

## Prerequisites

On **every** node:

```bash
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

## Install

```bash
./install.sh
kubectl -n longhorn-system get pods -o wide
kubectl get storageclass
```

Creates:

| StorageClass | Replicas | Use |
|--------------|----------|-----|
| `longhorn` (chart default) | 2 | general |
| `longhorn-postgres` | 2 | CNPG data/WAL |
| `longhorn-replicated` | 2 | other stateful apps |

Optional UI Ingress: edit `manifests/ui-ingress.yaml` host, then apply.
