# Getting started

End-to-end path from empty VMs to a working platform with Postgres HA on AWS S3.

## 0. Prerequisites

- 3 Linux VMs (Ubuntu 22.04+ recommended) with private networking
- Public IP on the head (or a LB) for Ingress / API
- DNS provider you can edit
- AWS account + CLI for the S3 bucket
- `kubectl`, `helm`, `aws` on your laptop (or use the head node)

## 1. Configure secrets locally

```bash
cd head
cp .env.example .env
# Set HEAD_* IPs, domains, ACME_EMAIL, Traefik password,
# Postgres passwords, AWS_ACCESS_KEY_ID / SECRET / REGION / bucket path
```

```bash
cd worker
cp .env.example .env
# HEAD_PRIVATE_IP only for now; add K3S_TOKEN after step 2
```

```bash
cp deployment-setup/secrets/00-namespace-secrets.example.yaml \
   deployment-setup/secrets/00-namespace-secrets.yaml
# Same Postgres passwords + AWS keys as head/.env
```

## 2. Boot the head node

On the control-plane VM (or copy `head/` there):

```bash
sudo ./boot.sh
```

Save the printed **node token**. Put it in `worker/.env` as `K3S_TOKEN`.

## 3. Join workers

On each worker VM:

```bash
sudo ./boot.sh
```

Verify from the head:

```bash
kubectl get nodes -o wide
# Expect 3 Ready nodes
```

## 4. Install platform components

From a machine with kubeconfig:

```bash
set -a; source head/.env; set +a
./deployment-setup/install-platform.sh
```

This installs (in order):

1. Namespaces  
2. Secrets (if present)  
3. Longhorn + StorageClasses  
4. cert-manager + Let's Encrypt issuers  
5. Traefik dashboard  
6. Portainer (ClusterIP) + Tailscale private Ingress (if `TS_CLIENT_*` set)  
7. CloudNativePG **operator** (not the DB yet)

## 5. Deploy Postgres → AWS S3

1. Create the bucket and IAM user — [aws-s3-backups.md](aws-s3-backups.md)  
2. Edit `destinationPath` in `operators/cnpg/manifests/02-cnpg-cluster.yaml`  
3. Apply:

```bash
kubectl apply -f operators/cnpg/manifests/02-cnpg-cluster.yaml
kubectl -n postgres get pods -o wide
kubectl -n postgres cnpg status postgres-ha
```

## 6. Demo apps

```bash
kubectl apply -f examples/hello.yaml
sed "s/app.example.com/${APP_HOST}/g" examples/example-web-app.yaml | kubectl apply -f -
```

## Checklist

- [ ] 3 nodes Ready  
- [ ] `kubectl get clusterissuer` shows Ready  
- [ ] Portainer opens on Tailscale MagicDNS only (`https://portainer.<tailnet>.ts.net`)  
- [ ] No public Portainer Ingress (`kubectl -n portainer get ingress`)  
- [ ] CNPG 3 pods on 3 nodes  
- [ ] Objects appear under `s3://…/postgres-ha/`  
- [ ] Example Ingress gets a Certificate  
