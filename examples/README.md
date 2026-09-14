# Examples

| File | What it shows |
|------|----------------|
| `hello.yaml` | Tiny echo app in `demo` (no Ingress) |
| `example-web-app.yaml` | Nginx + Traefik Ingress + Let's Encrypt staging |
| `postgres-connection.yaml` | ConfigMap/Secret pattern for apps → CNPG |

```bash
kubectl apply -f examples/hello.yaml

sed "s/app.example.com/app.yourdomain.com/g" examples/example-web-app.yaml \
  | kubectl apply -f -

kubectl apply -f examples/postgres-connection.yaml
```

Connect strings after CNPG is healthy:

```text
RW:      postgres-ha-rw.postgres.svc:5432
RO:      postgres-ha-ro.postgres.svc:5432
Pooler:  postgres-ha-pooler-rw.postgres.svc:5432
DB/user: appdb / app
```
