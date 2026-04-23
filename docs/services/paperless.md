# Paperless-ngx

Document management system with OCR, full-text search, and Google OIDC login.

## Stack

| Component | Image | Stateful |
|---|---|---|
| `paperless-db` | `postgres:18-alpine` | yes — PostgreSQL |
| `paperless-redis` | `redis:8` | no — task queue |
| `paperless-webserver` | `ghcr.io/paperless-ngx/paperless-ngx:2.20.14` | yes — data + media |
| `paperless-gotenberg` | `gotenberg/gotenberg:8.31` | no |
| `paperless-tika` | `apache/tika:3.2.3.0` | no |

## Manifests

```
apps/paperless/
├── paperless.yaml                  ← Namespace, PVCs, Deployments, Services
├── paperless-secrets.sops.yaml     ← SOPS-encrypted secrets
├── paperless-ingress.yaml          ← .gitignore (host: paperless.<your-domain>)
```

## Secrets

Managed via SOPS in `paperless-secrets.sops.yaml`:

| Key | Description |
|---|---|
| `PAPERLESS_SECRET_KEY` | Django secret key — must not change (invalidates sessions) |
| `POSTGRES_PASSWORD` | PostgreSQL superuser password |
| `PAPERLESS_DBPASS` | App DB password (= `POSTGRES_PASSWORD`) |
| `PAPERLESS_URL` | Public URL |
| `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | Google OAuth JSON (client_id + secret) |

## Storage

| PVC | Mount | Size |
|---|---|---|
| `paperless-postgres` | `/var/lib/postgresql/data` | 10 Gi |
| `paperless-data` | `/usr/src/paperless/data` | 5 Gi |
| `paperless-media` | `/usr/src/paperless/media` | 50 Gi |

> `PGDATA=/var/lib/postgresql/data` is set explicitly — postgres:18 uses a
> version-specific subdirectory by default which conflicts with the PVC mount.

## Access

- URL: https://paperless.<your-domain> (nginx → k3s Traefik → paperless-webserver)
- Login: Google OIDC only (`PAPERLESS_DISABLE_REGULAR_LOGIN=true`)
- New user registration disabled (`PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS=false`)

## Backup

Handled by `scripts/backup.sh` (`backup_paperless` function):
- `pg_dumpall` from `paperless-db` pod → gzip → staging dir
- `paperless-media` and `paperless-data` PVCs read directly from the local-path filesystem (`/var/lib/rancher/k3s/storage/`) — no local copy needed
- All three paths uploaded in one Restic snapshot tagged `paperless` → Hetzner S3

## Common operations

```bash
# Check pod status
kubectl get pods -n paperless

# Stream webserver logs
kubectl logs -n paperless -l app=paperless-webserver -f

# DB shell
kubectl exec -it -n paperless $(kubectl get pod -n paperless -l app=paperless-db -o jsonpath='{.items[0].metadata.name}') -- psql -U paperless paperless

# Scale down for maintenance
kubectl scale deployment paperless-webserver -n paperless --replicas=0
kubectl scale deployment paperless-webserver -n paperless --replicas=1
```
