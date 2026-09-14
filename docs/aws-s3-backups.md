# AWS S3 backups (CloudNativePG)

Postgres continuous archiving and base backups go to **Amazon S3** via Barman
(built into CloudNativePG). There is no in-cluster MinIO in this repo.

## 1. Create a bucket

```bash
export AWS_REGION=us-east-1
export BUCKET=your-company-k3s-postgres-backups   # must be globally unique

aws s3 mb "s3://${BUCKET}" --region "$AWS_REGION"

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Optional: default encryption
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{
  "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
}'
```

## 2. IAM user (or role)

Least-privilege policy example:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::your-company-k3s-postgres-backups"],
      "Condition": {
        "StringLike": { "s3:prefix": ["postgres-ha/*"] }
      }
    },
    {
      "Sid": "Objects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectAttributes"
      ],
      "Resource": ["arn:aws:s3:::your-company-k3s-postgres-backups/postgres-ha/*"]
    }
  ]
}
```

Create an access key and store it in Kubernetes:

```yaml
# deployment-setup/secrets/00-namespace-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-s3-credentials
  namespace: postgres
type: Opaque
stringData:
  ACCESS_KEY_ID: AKIA...
  ACCESS_SECRET_KEY: ...
  AWS_REGION: us-east-1
```

```bash
kubectl apply -f deployment-setup/secrets/00-namespace-secrets.yaml
```

## 3. Point the Cluster at the bucket

In `operators/cnpg/manifests/02-cnpg-cluster.yaml`:

```yaml
backup:
  retentionPolicy: "14d"
  barmanObjectStore:
    destinationPath: s3://your-company-k3s-postgres-backups/postgres-ha/
    # Do NOT set endpointURL for normal AWS S3
    s3Credentials:
      accessKeyId:
        name: postgres-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: postgres-s3-credentials
        key: ACCESS_SECRET_KEY
      region:
        name: postgres-s3-credentials
        key: AWS_REGION
```

Also set matching values in `head/.env`:

```bash
AWS_REGION=us-east-1
AWS_S3_BUCKET=your-company-k3s-postgres-backups
AWS_S3_DESTINATION_PATH=s3://your-company-k3s-postgres-backups/postgres-ha/
```

## 4. Apply and verify

```bash
kubectl apply -f operators/cnpg/manifests/02-cnpg-cluster.yaml

# Wait for cluster healthy
kubectl -n postgres cnpg status postgres-ha

# ScheduledBackup creates an immediate backup on first apply (immediate: true)
kubectl -n postgres get backup,scheduledbackup

# Objects in AWS
aws s3 ls s3://your-company-k3s-postgres-backups/postgres-ha/ --recursive | head
```

## 5. Restore sketch

```bash
# List backups
kubectl -n postgres get backup

# Bootstrap a new Cluster from object store (see CNPG docs: recovery.from.objectStore)
# Point barmanObjectStore / serverName at the same destinationPath.
```

Official reference: [CloudNativePG — Backup on object stores](https://cloudnative-pg.io/documentation/current/backup_barmanobjectstore/).
