# CloudNativePG operator

HA Postgres (1 primary + 2 replicas across 3 nodes) with Barman continuous
archiving and base backups to **AWS S3**.

## Prerequisites

- 3 Ready nodes (`kubectl get nodes`)
- Longhorn (or another RWX/RWO storage class) — see `operators/longhorn/`
- AWS S3 bucket in your chosen region
- IAM credentials with access to that bucket/prefix
- Secrets applied from `deployment-setup/secrets/`

## AWS S3 setup (once)

```bash
# Example bucket (pick a globally unique name)
aws s3 mb s3://your-company-k3s-postgres-backups --region us-east-1

# Block public access (recommended)
aws s3api put-public-access-block \
  --bucket your-company-k3s-postgres-backups \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

IAM policy sketch (attach to the backup user):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::your-company-k3s-postgres-backups"],
      "Condition": {
        "StringLike": { "s3:prefix": ["postgres-ha/*"] }
      }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::your-company-k3s-postgres-backups/postgres-ha/*"]
    }
  ]
}
```

Put the access key into `deployment-setup/secrets/00-namespace-secrets.yaml`
(`postgres-s3-credentials`) and set `destinationPath` in
`manifests/02-cnpg-cluster.yaml` to `s3://your-company-k3s-postgres-backups/postgres-ha/`.

## Setup steps

```bash
# 1. Install operator
./install-operator.sh

# 2. Apply DB + AWS S3 secrets
cp ../../deployment-setup/secrets/00-namespace-secrets.example.yaml \
   ../../deployment-setup/secrets/00-namespace-secrets.yaml
# edit passwords + AWS keys
kubectl apply -f ../../deployment-setup/secrets/00-namespace-secrets.yaml

# 3. Edit destinationPath in manifests/02-cnpg-cluster.yaml to your bucket
# 4. Deploy cluster (3 instances) + pooler + daily ScheduledBackup
kubectl apply -f manifests/02-cnpg-cluster.yaml

# 5. Verify
kubectl -n postgres get cluster,pods,pvc,scheduledbackup,backup -o wide
kubectl -n postgres cnpg status postgres-ha

# 6. Confirm objects land in AWS
aws s3 ls s3://your-company-k3s-postgres-backups/postgres-ha/ --recursive
```

## Topology

| Setting | Value |
|---------|--------|
| Instances | 3 (preferred anti-affinity on `kubernetes.io/hostname`) |
| Sync | `method: any`, `number: 1` |
| Backups | Barman → **AWS S3** |
| Retention | 14 days |
| Schedule | Daily `02:30` UTC (`0 30 2 * * *`) |

## Services

- RW: `postgres-ha-rw.postgres.svc:5432`
- RO: `postgres-ha-ro.postgres.svc:5432`
- Pooler RW: `postgres-ha-pooler-rw.postgres.svc:5432`
