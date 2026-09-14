# Deploy an app

Repeatable pattern for every service in the `apps` namespace.

## 1. Namespace

Already created by `deployment-setup/namespaces/`. For a new product area:

```bash
kubectl create namespace myproduct
kubectl label namespace myproduct app.kubernetes.io/part-of=k3s-platform
```

## 2. Workload + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: apps
spec:
  replicas: 2
  selector:
    matchLabels: { app: myapp }
  template:
    metadata:
      labels: { app: myapp }
    spec:
      containers:
        - name: web
          image: ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: apps
spec:
  selector: { app: myapp }
  ports: [{ port: 80, targetPort: 8080 }]
```

## 3. Ingress + TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: apps
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["myapp.example.com"]
      secretName: myapp-tls
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port: { number: 80 }
```

DNS: `myapp.example.com` A → head public IP.

## 4. Talk to Postgres

```yaml
# See examples/postgres-connection.yaml
DATABASE_HOST: postgres-ha-rw.postgres.svc   # or postgres-ha-pooler-rw.postgres.svc
DATABASE_PORT: "5432"
DATABASE_NAME: appdb
```

Create an app Secret with the same password as `postgres-app-secret`, or sync
with External Secrets.

## 5. Verify

```bash
kubectl -n apps get deploy,svc,ingress,certificate
curl -I https://myapp.example.com
```

Full demo: `examples/example-web-app.yaml`.
