# k3s Platform — Master Document

**System Design Document and User Manual**

A production-oriented, 3-node k3s platform: 1 control-plane (head) node and 2
workers, delivering ingress with automatic TLS, replicated block storage,
highly-available PostgreSQL, and a private admin UI. This document is the single
reference for the architecture, the installation and operation procedures, and
the security model.

- **Audience:** operators who install, run, and secure the platform.
- **Status:** verified end to end on a live 3-node deployment (k3s v1.36.4+k3s1).
- **Companion files:** `README.md` (quick start), `docs/` (topic guides).

---

## Table of Contents

**Part I — System Design**
1. [Purpose and scope](#1-purpose-and-scope)
2. [Architecture overview](#2-architecture-overview)
3. [Node and network topology](#3-node-and-network-topology)
4. [Component inventory](#4-component-inventory)
5. [Storage design](#5-storage-design)
6. [Database design (PostgreSQL HA)](#6-database-design-postgresql-ha)
7. [Ingress, DNS, and TLS](#7-ingress-dns-and-tls)
8. [Security architecture](#8-security-architecture)
9. [Namespace model](#9-namespace-model)

**Part II — User Manual**
10. [Prerequisites](#10-prerequisites)
11. [Installation](#11-installation)
12. [Configuration reference](#12-configuration-reference)
13. [Day-two operations](#13-day-two-operations)
14. [Administrative access](#14-administrative-access)
15. [Security operations](#15-security-operations)
16. [Troubleshooting](#16-troubleshooting)

**Appendices**
- [A. Hardening and fixes applied](#appendix-a-hardening-and-fixes-applied)
- [B. Reference deployment](#appendix-b-reference-deployment)

---

# Part I — System Design

## 1. Purpose and scope

The platform bootstraps a small, self-contained Kubernetes cluster suitable for
hosting web applications backed by a highly-available relational database, with
the following goals:

- **Simplicity:** k3s provides a single-binary Kubernetes with sane defaults.
- **Resilience:** storage and the database survive the loss of one node.
- **Secure by default:** admin surfaces are private, tenant workloads are
  isolated, and secrets are encrypted at rest.
- **Reproducibility:** every node and platform component installs from scripts
  and manifests checked into this repository.

Out of scope: multi-region topology, cluster autoscaling, and a managed control
plane. The control plane is a single node; see
[Operational limits](#operational-limits-and-risks).

## 2. Architecture overview

```text
                 Internet (Cloudflare proxy)
                     │  :80 / :443
                     ▼
        ┌────────────────────────────┐        Private admin path
        │  Head node (control-plane) │        (Tailscale tailnet)
        │  Traefik ingress + TLS     │              │
        │  ├─ apps (your workloads)  │              ▼
        │  └─ cert-manager (ACME)    │      Portainer UI (ClusterIP)
        └────────────┬───────────────┘   https://portainer.<tailnet>.ts.net
                     │ private network (10.0.0.0/24)
        ┌────────────┴───────────────┐
        ▼                            ▼
   Worker node 1                Worker node 2
        │                            │
        └──────────┬─────────────────┘
                   ▼
   Longhorn replicated block storage (2 replicas)
                   │
                   ▼
   CloudNativePG: 1 primary + 2 replicas (one per node)
                   │  WAL + base backups (optional)
                   ▼
   Object storage (S3 / MinIO)
```

Traffic reaches applications over the public internet through Cloudflare, then
Traefik. Administrative interfaces (Portainer) are never published publicly; they
are reached over a private Tailscale tailnet. The Kubernetes API and kubelet are
restricted to the private network by a host firewall.

## 3. Node and network topology

| Role | vCPU / RAM (reference) | Interfaces | Purpose |
|------|------------------------|-----------|---------|
| Head (control-plane) | 4 / 7 GB | public + private | API server, scheduler, Traefik, one DB instance |
| Worker × 2 | 2 / 3 GB each | public + private | Workloads, storage replicas, DB replicas |

**Networking rules**

- Each node has a **public** address (application ingress, SSH) and a **private**
  address on a shared L2/L3 network (`10.0.0.0/24` in the reference deployment).
- The cluster uses the **private** interface for the Kubernetes API join
  (`https://<head-private-ip>:6443`), node-to-node traffic, and Flannel VXLAN.
  Set `FLANNEL_IFACE` and node IPs to the private interface.
- Only ports **80**, **443**, and the **SSH** port are reachable from the
  internet. The API (**6443**) and kubelet (**10250**) are dropped on the public
  interface by the boot scripts.

## 4. Component inventory

| Component | Version (reference) | Role |
|-----------|---------------------|------|
| k3s | v1.36.4+k3s1 | Kubernetes distribution (server + agents) |
| Traefik | 3.7.x | Ingress controller, TLS termination, dashboard |
| cert-manager | v1.21.x | ACME (Let's Encrypt) certificate issuance |
| Longhorn | v1.12.x | Replicated block storage + CSI |
| CloudNativePG | 1.30.x | PostgreSQL operator (HA, failover, backups) |
| PostgreSQL | 17.5 | Database engine (3 instances) |
| Portainer CE | 2.45.x | Cluster management UI (private) |
| Tailscale operator | latest | Private ingress for admin UIs |

Component versions track upstream stable channels; pin them in the operator
scripts for reproducible installs.

## 5. Storage design

Longhorn provides distributed block storage built from local disks on each node.

- **Replication:** volumes keep **2 replicas** on different nodes, so a single
  node failure does not lose data (`replicaSoftAntiAffinity: false` enforces
  spreading).
- **StorageClasses:**
  - `longhorn` — **the single cluster default** (Delete reclaim policy).
  - `longhorn-postgres` — for database volumes, **Retain** reclaim policy so a
    dropped PVC does not erase data; `dataLocality: best-effort`.
  - `longhorn-replicated` — general replicated storage, Delete reclaim.
  - `longhorn-static` — for pre-provisioned volumes.
- **k3s local-path is intentionally disabled** (`disable: local-storage`).
  Leaving it installed produces two default StorageClasses, and k3s re-applies
  its default annotation on every restart, so it cannot be reliably demoted —
  disabling the addon is the durable fix.

Each node must have an iSCSI initiator (`open-iscsi`) and NFS client
(`nfs-common`), and `multipathd` must not claim Longhorn's block devices. The
boot scripts install these prerequisites and add a multipath blacklist
automatically.

## 6. Database design (PostgreSQL HA)

CloudNativePG runs a 3-instance PostgreSQL cluster:

- **Topology:** 1 primary + 2 synchronous replicas, one instance per node
  (pod anti-affinity). Quorum-based synchronous replication (`method: any`,
  `number: 1`) keeps at least one replica in sync with the primary.
- **Failover:** unsupervised; the operator promotes a replica automatically if
  the primary fails, and rejoins the old primary as a replica.
- **Connection endpoints (in-cluster):**
  - Read/write: `postgres-ha-rw.postgres.svc:5432`
  - Read-only: `postgres-ha-ro.postgres.svc:5432`
  - Pooled read/write (PgBouncer): `postgres-ha-pooler-rw.postgres.svc:5432`
- **Authentication:** `scram-sha-256` for clients; certificate-based auth for
  replication and the pooler (enforced by `pg_hba.conf`).
- **Storage:** `longhorn-postgres` (Retain) for data and WAL volumes.
- **Backups (optional):** Barman to S3-compatible object storage, plus a daily
  `ScheduledBackup`. Backups require object-storage credentials; when they are
  absent the cluster runs without the backup stanza (see
  [Configure backups](#configure-postgresql-backups)).

## 7. Ingress, DNS, and TLS

- **Ingress controller:** Traefik (bundled with k3s), exposed on the host via a
  ServiceLB DaemonSet on ports 80/443.
- **DNS:** Application hostnames are `A` records pointing at the head node's
  public IP. In the reference deployment they sit behind the **Cloudflare
  proxy**.
- **TLS:** cert-manager issues certificates from Let's Encrypt via the HTTP-01
  challenge. Two `ClusterIssuer`s exist:
  - `letsencrypt-staging` — for validation without hitting rate limits.
  - `letsencrypt-prod` — for trusted certificates.
- **Cloudflare interaction:** the ACME HTTP-01 challenge passes through the
  Cloudflare proxy. For the challenge and for a strict origin certificate, set
  Cloudflare SSL mode to **Full (strict)** and, during first issuance, either
  grey-cloud the record briefly or ensure the `/.well-known/acme-challenge/`
  path reaches the origin. See [Issue certificates](#issue-and-verify-tls).

> **Note:** the Kubernetes API (6443) is private-only. It is **not** proxied by
> Cloudflare and is firewalled on the public interface, so remote `kubectl`
> access must use the private network or a VPN/tailnet.

## 8. Security architecture

The platform applies defense in depth. Controls verified on the live cluster:

| Layer | Control |
|-------|---------|
| Host firewall | API (6443) and kubelet (10250) dropped on the public interface; persisted across reboot. Only 80/443/SSH are public. |
| API authentication | Anonymous access rejected (HTTP 401); kubelet rejects anonymous requests. |
| Secrets at rest | k3s `secrets-encryption` enabled (AES-CBC). Stored secrets are ciphertext (`k8s:enc:aescbc:...`), not plaintext. |
| Pod Security Admission | `baseline` **enforced** on `apps`, `demo`, `postgres`, `portainer` — privileged containers, host namespaces, host ports, and hostPath volumes are rejected. `restricted` is set as a warning. |
| Network isolation | Default-deny ingress per tenant/data namespace, with explicit allows: apps and demo accept traffic only from Traefik and their own namespace; postgres accepts only its own namespace, the CNPG operator, and the apps namespace; portainer accepts only Traefik and the Tailscale operator. |
| Admin UI exposure | Portainer is ClusterIP-only, reachable solely over the Tailscale tailnet — never a public Ingress. |
| Database auth | `scram-sha-256` for clients; certificate auth for replication and pooler. |
| Secret handling | The Tailscale OAuth secret is passed to Helm via a mode-600 values file, not the command line, so it does not appear in the process list. |
| Kubeconfig | The admin kubeconfig is mode 0600 (root only); a per-user readable copy is installed for the operator account. |

**Verified negative tests**

- A privileged pod mounting the host root filesystem is **rejected** by PSA in
  tenant namespaces.
- A pod in `demo` **cannot** reach PostgreSQL or Portainer (network policy),
  while DNS and legitimate `apps → postgres` traffic still work.
- The default ServiceAccount in a tenant namespace has **no** RBAC permissions
  (cannot list secrets, pods, or nodes).

### Operational limits and risks

- **Single control-plane node.** Losing the head node takes down the API server
  (running workloads continue, but scheduling and the DB primary may be
  affected). For higher availability, run an HA embedded-etcd control plane.
- **Cloudflare bypass.** If the origin serves any `Host`, an attacker who learns
  the origin IP can bypass Cloudflare WAF rules. Mitigate by restricting ports
  80/443 to Cloudflare IP ranges at the host firewall and using **Full (strict)**
  SSL.
- **Backups are opt-in.** Without object-storage credentials, PostgreSQL runs
  without off-site backups. Configure them before production use.

## 9. Namespace model

| Namespace | Contents | PSA enforce |
|-----------|----------|-------------|
| `apps` | Production/staging application Deployments | baseline |
| `demo` | Throwaway smoke tests | baseline |
| `postgres` | CloudNativePG cluster, pooler, (optional) backups | baseline |
| `portainer` | Portainer CE | baseline |
| `cert-manager` | ACME certificate machinery | (privileged infra) |
| `cnpg-system` | CloudNativePG operator | (privileged infra) |
| `longhorn-system` | Longhorn storage engine and UI | (privileged infra) |
| `kube-system` | Traefik, CoreDNS, k3s internals | (privileged infra) |

Operator/infrastructure namespaces run trusted components that legitimately need
elevated privileges and are intentionally left unlabelled. Do not run tenant
workloads in them.

---

# Part II — User Manual

## 10. Prerequisites

- Three Ubuntu 24.04 hosts (1 head + 2 workers), each with a public and a
  private network interface, and SSH access as a sudo-capable user.
- A domain you control, with the ability to create `A` records.
- (Optional) A Tailscale account and OAuth client for private admin access.
- (Optional) S3-compatible object storage and credentials for database backups.
- A workstation with `kubectl` for platform administration.

The boot scripts install node-level prerequisites automatically
(`open-iscsi`, `nfs-common`, iSCSI service, multipath blacklist, firewall).

## 11. Installation

Install in three stages: head node, workers, then the platform.

### 11.1 Head node (control plane)

On the head VM:

```bash
cd head
cp .env.example .env      # then edit — see the configuration reference
sudo ./boot.sh
```

`boot.sh` installs node prerequisites, writes the k3s server config (secrets
encryption on, local-storage disabled, kubeconfig mode 0600), installs k3s,
applies the host firewall, and installs a per-user kubeconfig. On completion it
prints the **node token** — copy it for the workers.

### 11.2 Workers

On each worker VM:

```bash
cd worker
cp .env.example .env      # set HEAD_PRIVATE_IP and K3S_TOKEN from the head
sudo ./boot.sh
```

The worker auto-detects its **private** IP (or set `WORKER_PRIVATE_IP`
explicitly), joins the cluster over the private network, and applies the kubelet
firewall.

Verify from the head:

```bash
kubectl get nodes -o wide     # all nodes Ready, InternalIP on the private network
```

### 11.3 Platform components

From a machine with `kubectl` pointed at the cluster:

```bash
# Create the real secrets file (gitignored) and fill in values
cp deployment-setup/secrets/00-namespace-secrets.example.yaml \
   deployment-setup/secrets/00-namespace-secrets.yaml
# edit AWS/object-storage keys + Postgres passwords

./deployment-setup/install-platform.sh
```

This applies namespaces (with PSA labels), NetworkPolicies, Longhorn (and demotes
local-path if present), cert-manager and ClusterIssuers, Traefik dashboard
config, Portainer (ClusterIP), the optional Tailscale operator, and the CNPG
operator.

### 11.4 Database and demo app

```bash
# PostgreSQL HA (edit destinationPath for backups first, or remove the backup
# stanza if no object storage is configured)
kubectl apply -f operators/cnpg/manifests/02-cnpg-cluster.yaml

# Demo application on your domain
sed "s/app.example.com/app.yourdomain.com/g" \
  examples/example-web-app.yaml | kubectl apply -f -
```

## 12. Configuration reference

`head/.env` (control plane):

| Variable | Meaning |
|----------|---------|
| `HEAD_PRIVATE_IP` / `HEAD_PUBLIC_IP` | Head node private and public addresses |
| `FLANNEL_IFACE` | Private network interface (e.g. `enp7s0`) |
| `CLUSTER_DOMAIN` / `API_HOST` | API TLS SAN hostname |
| `BASE_DOMAIN`, `TRAEFIK_HOST`, `APP_HOST`, `LONGHORN_HOST` | Public hostnames (A records → head public IP) |
| `ACME_EMAIL` | Contact for Let's Encrypt |
| `TRAEFIK_DASH_USER` / `TRAEFIK_DASH_PASS` | Traefik dashboard basic auth |
| `TS_CLIENT_ID` / `TS_CLIENT_SECRET` | Tailscale OAuth client (private Portainer) |
| `INSTALL_TAILSCALE` | `true` to install the Tailscale operator |
| `POSTGRES_APP_PASSWORD` / `POSTGRES_SUPERUSER_PASSWORD` | Database passwords |
| `AWS_*` | Object-storage credentials and bucket for backups |
| `SSH_USER` / `SSH_PORT` / `SSH_KEY` | Optional inventory for remote orchestration |

`worker/.env` (each worker):

| Variable | Meaning |
|----------|---------|
| `HEAD_PRIVATE_IP` | Head private IP (join target) |
| `K3S_TOKEN` | Node token from the head |
| `WORKER_PRIVATE_IP` | Override auto-detected private IP if needed |
| `FLANNEL_IFACE` | Private network interface |

> Secrets live only in `.env` and real secret YAML files, all gitignored. Never
> commit them. The repository is intended to be shareable without secrets.

## 13. Day-two operations

### Deploy an application

Create a Deployment, Service, and Ingress. Annotate the Ingress with a
ClusterIssuer for automatic TLS:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
```

Point the Ingress `host` at a DNS record that resolves to the head public IP.
See `docs/deploy-an-app.md` and `examples/`.

### Connect to PostgreSQL

Applications in `apps` connect using the app credentials:

```text
host: postgres-ha-rw.postgres.svc      # read/write
host: postgres-ha-ro.postgres.svc      # read-only replicas
host: postgres-ha-pooler-rw.postgres.svc  # pooled read/write
port: 5432
```

Network policy permits the `apps` namespace to reach PostgreSQL; other tenant
namespaces are denied.

### Configure PostgreSQL backups

1. Provide object-storage credentials in the secrets file
   (`postgres-s3-credentials`).
2. Set `destinationPath` (and `endpointURL` for non-AWS S3) in
   `operators/cnpg/manifests/02-cnpg-cluster.yaml`.
3. Apply the manifest. The included `ScheduledBackup` runs daily; trigger an
   immediate one with a `Backup` resource. Verify with
   `kubectl -n postgres get backup`.

### Issue and verify TLS

- Start with `letsencrypt-staging` to validate end to end, then switch the
  Ingress annotation to `letsencrypt-prod`.
- If a certificate stays `False`/pending, check the ACME `Order` and `Challenge`
  objects and confirm the hostname resolves and the challenge path reaches the
  origin (see Troubleshooting).

## 14. Administrative access

### kubectl on the head

The operator account has `KUBECONFIG=$HOME/.kube/config` exported (server
`https://127.0.0.1:6443`). Run `kubectl` directly.

### Remote kubectl

The API is private-only. Access it over the private network or a VPN/tailnet at
`https://<head-private-ip>:6443`, using a copy of the admin kubeconfig with the
server rewritten to that address.

### Portainer (private)

Portainer is ClusterIP-only. With the Tailscale operator installed, reach it at
`https://portainer.<your-tailnet>.ts.net` from a device on your tailnet. Do
**not** apply `operators/portainer/manifests/ingress-public.optional.yaml`
unless you deliberately accept public exposure with strong auth.

### Traefik dashboard

Protected by basic auth (`TRAEFIK_DASH_USER` / `TRAEFIK_DASH_PASS`) at
`TRAEFIK_HOST`.

## 15. Security operations

- **Rotate the secrets-encryption key:**
  `sudo k3s secrets-encrypt rotate-keys`, then restart k3s and
  `sudo k3s secrets-encrypt reencrypt --force`.
- **Confirm encryption at rest:** `sudo k3s secrets-encrypt status` shows
  `Encryption Status: Enabled`.
- **Review firewall:** `sudo iptables -S INPUT | grep k3s-block-public` on each
  node; rules are persisted in `/etc/iptables/rules.v4`.
- **Tighten a namespace to `restricted`:** once its workloads set
  `runAsNonRoot`, drop capabilities, and a seccomp profile, change its
  `pod-security.kubernetes.io/enforce` label to `restricted`.
- **Harden Cloudflare:** set SSL mode to **Full (strict)** and restrict ports
  80/443 at the host firewall to Cloudflare IP ranges to prevent origin bypass.

## 16. Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `boot.sh` exits immediately with no output | (Fixed in current scripts) a `require_root` return code aborting under `set -e` | Ensure you run the current scripts; run as root (`sudo`). |
| Worker joins on its public IP | Auto-detection picked a public address | Set `WORKER_PRIVATE_IP` in `worker/.env`. |
| Longhorn PVC stuck; `mke2fs ... in use by the system` | `multipathd` claimed the Longhorn device | Boot scripts add a multipath blacklist; if pre-existing, add the blacklist and restart `multipathd`, then delete the stuck initdb pod. |
| Two default StorageClasses | k3s local-path plus Longhorn | Current config disables local-storage; verify `disable: local-storage` in the k3s config. |
| `kubectl` on the head: `permission denied` reading k3s.yaml | Kubeconfig is mode 0600 | Use the per-user copy: `export KUBECONFIG=$HOME/.kube/config`. |
| Certificate stays pending | DNS not resolving or challenge blocked | Confirm the `A` record exists; grey-cloud during first issuance or ensure `/.well-known/acme-challenge/` reaches the origin. |
| Remote `kubectl` to `api.<domain>:6443` fails | API is private-only and firewalled | Use the private endpoint over the tailnet/VPN. |

---

# Appendix A. Hardening and fixes applied

The following defects in the original repository were fixed, and the
corresponding hardening was applied to both the repository and the live cluster.

**Blocking install bugs**

1. `require_root()` in both boot scripts aborted the script under `set -e` when
   run correctly as root — rewritten as an explicit `if` block.
2. Worker private-IP auto-detection selected the public IP on cloud hosts — now
   prefers an RFC1918 address and honours `WORKER_PRIVATE_IP`.
3. The head kubeconfig `sed` never matched (`0.0.0.0` vs `127.0.0.1`) and logged
   a false success — corrected, with the on-host server normalised to loopback.
4. Longhorn prerequisites and the multipath blacklist were documented but not
   automated — now installed by the boot scripts.

**Security hardening**

5. Host firewall added (API 6443, kubelet 10250 dropped on the public
   interface; persisted).
6. Secrets encryption at rest enabled and existing secrets re-encrypted.
7. Pod Security Admission (`baseline` enforce) added to tenant/data namespaces.
8. NetworkPolicies added for namespace isolation.
9. Single default StorageClass ensured by disabling k3s local-storage.
10. Kubeconfig tightened to 0600 with a per-user readable copy.
11. Tailscale OAuth secret passed via a mode-600 values file rather than the
    command line.

# Appendix B. Reference deployment

The procedures above were verified on a live 3-node deployment on Hetzner Cloud
(Falkenstein), domain `thebaremetal.com`, private network `10.0.0.0/24`, SSH on a
non-default port. Final verified state: 3 nodes Ready; PostgreSQL 3/3 healthy
with 2 replicas streaming; secrets encryption enabled; a single default
StorageClass; 6443/10250 closed to the internet on all nodes; PSA and
NetworkPolicies enforcing as designed.
