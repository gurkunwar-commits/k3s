# Namespaces

How this repo organizes workloads. Apply the baseline set with:

```bash
kubectl apply -f deployment-setup/namespaces/00-namespaces.yaml
```

## Sample map

| Namespace | Created by | Purpose | Typical objects |
|-----------|------------|---------|-----------------|
| `apps` | `deployment-setup` | Your services | Deployment, Service, Ingress, ConfigMap, Secret |
| `postgres` | `deployment-setup` | Database HA | CNPG `Cluster`, `Pooler`, `ScheduledBackup`, Secrets |
| `demo` | `deployment-setup` | Experiments | hello Deployment/Service |
| `portainer` | `deployment-setup` + Portainer manifest | Cluster UI | Deployment, Ingress, ServiceAccount |
| `cert-manager` | Helm (`operators/letsencrypt`) | ACME | cert-manager Deployments, ClusterIssuers (cluster-scoped) |
| `cnpg-system` | Helm (`operators/cnpg`) | Operator | CNPG controller |
| `longhorn-system` | Helm (`operators/longhorn`) | Storage | Longhorn manager / UI |
| `tailscale` | Helm (`operators/tailscale`) | Private Ingress | Tailscale operator + proxies |
| `kube-system` | k3s | Platform | Traefik, CoreDNS, metrics |

## Copy-paste sample (annotated)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    app.kubernetes.io/part-of: k3s-platform
    # Optional: environment=staging
---
apiVersion: v1
kind: Namespace
metadata:
  name: postgres
  labels:
    app.kubernetes.io/name: postgres-ha
    app.kubernetes.io/part-of: k3s-platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    app.kubernetes.io/part-of: k3s-platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: portainer
  labels:
    app.kubernetes.io/part-of: k3s-platform
```

## Conventions

1. **Apps never share the `postgres` namespace** — connect via Service DNS (`*.postgres.svc`).
2. **One Ingress host per app** (or path-based if you prefer); put TLS secrets in the app namespace.
3. **Secrets stay in the namespace that consumes them** (`postgres-s3-credentials` lives in `postgres`).
4. For multi-team clusters, add NetworkPolicies later; start with namespace isolation.

## Verify

```bash
kubectl get ns -l app.kubernetes.io/part-of=k3s-platform
kubectl get all -n apps
kubectl get all -n postgres
kubectl get all -n portainer
```
