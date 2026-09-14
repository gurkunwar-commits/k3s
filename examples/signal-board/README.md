# Signal Board — 3-tier demo app

A live, DB-backed demo that exercises the whole platform: a single-page frontend
talks to a **PostgREST** API, which reads and writes the **CloudNativePG** HA
cluster — all behind **Traefik** with a **Let's Encrypt** certificate.

```text
Browser ── HTTPS ──▶ Traefik ─┬─ /      ─▶ nginx (SPA)
                              └─ /api   ─▶ PostgREST ─▶ postgres-ha (HA)
```

- **Frontend** (`web/index.html`): posts messages, reacts to others, and shows
  live counters and a signal-mix chart, polling every few seconds.
- **API** (PostgREST): exposes the `api` schema — `entries` (feed), `stats` and
  `signal_counts` (aggregate views), and a `react()` RPC (an `UPDATE`).
- **Data** (`schema.sql`): tables, aggregate views, the `react` function, a
  read/insert-only `web_anon` role, and an `authenticator` login role that
  PostgREST connects as. Seed rows are inserted only if the table is empty.

Every message you post is an `INSERT`; every reaction is an `UPDATE` via the RPC;
the counters and chart are live aggregate queries.

## Deploy

```bash
DOMAIN=stg01-k3s.example.com ./deploy.sh
```

`deploy.sh` generates the `authenticator` password, applies the schema, creates
the `postgrest-db` Secret and the `web-index` ConfigMap, deploys PostgREST and
nginx, and creates the ingress + TLS. Point a DNS record for `DOMAIN` at the
ingress first.

## Security notes

- Runs in the `apps` namespace, so it inherits the platform's **NetworkPolicies**
  (Traefik → app, app → Postgres only) and **Pod Security Admission** (baseline;
  both containers run non-root with dropped capabilities).
- The database password exists only in the generated `postgrest-db` Secret —
  never in these manifests or in git.
- `web_anon` can read the feed and insert new entries (column-restricted); it
  cannot update or delete rows directly. Reactions go through the
  `SECURITY DEFINER` `react()` function, which only increments a counter.

## Remove

```bash
kubectl -n apps delete ingress web web-api
kubectl -n apps delete middleware strip-api
kubectl -n apps delete deploy web postgrest
kubectl -n apps delete svc web postgrest
kubectl -n apps delete configmap web-index
kubectl -n apps delete secret postgrest-db web-tls
# optional: drop the demo schema
# kubectl -n postgres exec -i postgres-ha-1 -c postgres -- \
#   psql -U postgres -h /controller/run -d appdb -c 'DROP SCHEMA api CASCADE;'
```
