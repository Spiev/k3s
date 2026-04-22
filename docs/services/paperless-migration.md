# Paperless-ngx Migration: Docker → k3s

> **Status:** Manifests ready — data migration pending.
>
> Source: `raspberrypi` → `~/docker/paperless/`

---

## Production safety

The Docker container on `raspberrypi` is **not touched** during this migration. All operations there are strictly read-only (pg_dump, rsync). The only change on the old Raspi is the nginx `proxy_pass` address in the final switch-over.

Full rollback at any time: revert the nginx config → Docker Paperless is immediately active again.

---

## Phase overview

| Phase | What | Where | Impact on production |
|---|---|---|---|
| 1 | Secrets erstellen + verschlüsseln | Laptop | None |
| 2 | Daten extrahieren: pg_dump + rsync | raspberrypi (read-only) | None |
| 3 | k3s deployment + Daten-Import | k3s node | None |
| 4 | Test via port-forward | Laptop | None |
| 5 | nginx switch + Ingress | raspberrypi (nginx only) | Low — sofortiger Rollback möglich |
| 6 | Cleanup | Überall | After validation |

---

## Stack overview

| Container | Image | Stateful? |
|---|---|---|
| `paperless-db` | `postgres:18-alpine` | yes — pg_dump required |
| `paperless-redis` | `redis:8.6` | no — task queue, starts fresh |
| `paperless-webserver` | `ghcr.io/paperless-ngx/paperless-ngx:2.20.14` | yes — data + media volumes |
| `paperless-gotenberg` | `gotenberg/gotenberg:8.31` | no — stateless |
| `paperless-tika` | `apache/tika:3.2.3.0` | no — stateless |

---

## Manifest structure

```
apps/paperless/
├── paperless.yaml                 ← Namespace, PVCs, all Deployments + Services
├── paperless-secrets.sops.yaml    ← SOPS-encrypted secrets (create from .example)
├── paperless-secrets.sops.yaml.example ← template
├── paperless-ingress.yaml         ← .gitignore (domain)
└── paperless-ingress.yaml.example ← template
```

---

## Phase 1 — Secrets erstellen

Get the values from `~/docker/paperless/.env` on `raspberrypi`:

```bash
ssh raspberrypi "grep -E 'PAPERLESS_SECRET_KEY|PAPERLESS_DBPASS|POSTGRES_PASSWORD|PAPERLESS_SOCIALACCOUNT_PROVIDERS|PAPERLESS_URL' ~/docker/paperless/.env"
```

Create and encrypt:

```bash
cp apps/paperless/paperless-secrets.sops.yaml.example apps/paperless/paperless-secrets.sops.yaml
# Fill in all values, then:
sops --encrypt --in-place apps/paperless/paperless-secrets.sops.yaml
git add apps/paperless/paperless-secrets.sops.yaml
git commit -m "feat(paperless): add encrypted secrets"
git push
```

> **`PAPERLESS_SECRET_KEY` must be identical** to the existing value — changing it invalidates all active sessions.
>
> **`PAPERLESS_URL`** stays the same as in the existing `.env` — nginx keeps the same hostname.

---

## Phase 2 — Daten extrahieren (read-only auf raspberrypi)

Find the exact container name:

```bash
ssh raspberrypi "docker ps --format '{{.Names}}' | grep paperless"
```

Create DB dump:

```bash
ssh raspberrypi "docker exec <db-container> pg_dump -U paperless paperless \
  | gzip > /tmp/paperless_$(date +%Y-%m-%d_%H_%M_%S).sql.gz"
```

Rsync volumes to laptop (read-only, no `--delete`):

```bash
rsync -av raspberrypi:~/docker/paperless/library/data/  /tmp/paperless-data/
rsync -av raspberrypi:~/docker/paperless/library/media/ /tmp/paperless-media/
```

> If the Docker volume paths differ from `library/data` and `library/media`, check with:
> `ssh raspberrypi "docker inspect <webserver-container> | grep -A5 Mounts"`

---

## Phase 3 — k3s deployment + Daten-Import

### Deploy (Flux reconciles after push)

```bash
# Secrets are already pushed via Flux — apply remaining manifests manually:
kubectl apply -f apps/paperless/paperless.yaml
```

Wait for postgres to be ready before importing:

```bash
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless-db --timeout=60s
```

> The webserver pod crash-loops until data is imported — that is expected.

### Import PostgreSQL

```bash
DB_POD=$(kubectl get pod -n paperless -l app=paperless-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/paperless_<TIMESTAMP>.sql.gz \
  | kubectl exec -i -n paperless "$DB_POD" -- psql -U paperless paperless
```

### Copy data and media volumes

Scale down webserver to prevent writes during copy:

```bash
kubectl scale deployment paperless-webserver -n paperless --replicas=0
```

Start a helper pod that mounts both PVCs:

```bash
kubectl run paperless-restore --image=alpine:3.23 --restart=Never -n paperless \
  --overrides='{
    "spec": {
      "volumes": [
        {"name": "data",  "persistentVolumeClaim": {"claimName": "paperless-data"}},
        {"name": "media", "persistentVolumeClaim": {"claimName": "paperless-media"}}
      ],
      "containers": [{
        "name": "paperless-restore",
        "image": "alpine:3.23",
        "command": ["sleep", "3600"],
        "volumeMounts": [
          {"name": "data",  "mountPath": "/data"},
          {"name": "media", "mountPath": "/media"}
        ]
      }]
    }
  }'

kubectl wait --for=condition=Ready pod -n paperless paperless-restore --timeout=30s
```

Copy files into PVCs:

```bash
kubectl cp /tmp/paperless-data/. paperless/paperless-restore:/data/
kubectl cp /tmp/paperless-media/. paperless/paperless-restore:/media/
kubectl delete pod -n paperless paperless-restore
```

Scale webserver back up:

```bash
kubectl scale deployment paperless-webserver -n paperless --replicas=1
kubectl get pods -n paperless -w
```

---

## Phase 4 — Test via port-forward

```bash
kubectl port-forward -n paperless svc/paperless-webserver 8080:8000
```

Browser: `http://localhost:8080`

Checklist:
- [ ] Google OIDC login works
- [ ] All documents visible, count matches Docker
- [ ] Document download works
- [ ] Search works
- [ ] Tags and correspondents intact

---

## Phase 5 — nginx switch + Ingress

This is the **only change on `raspberrypi`**.

### Ingress anlegen

```bash
cp apps/paperless/paperless-ingress.yaml.example apps/paperless/paperless-ingress.yaml
# Fill in hostname, then:
kubectl apply -f apps/paperless/paperless-ingress.yaml
```

### nginx config auf raspberrypi ändern

Find the existing Paperless nginx config on `raspberrypi`:

```bash
ssh raspberrypi "grep -rl 'paperless' /etc/nginx/sites-enabled/"
```

Change the `proxy_pass` from the local Docker port to Traefik on the k3s node:

```nginx
# Before:
proxy_pass http://localhost:<docker-port>;

# After:
proxy_pass http://<k3s-node-ip>:80;
```

Test and reload (no downtime, no container restart):

```bash
ssh raspberrypi "sudo nginx -t && sudo nginx -s reload"
```

### Verify

```bash
# DNS still resolves to raspberrypi nginx IP — no DNS change needed
curl -I https://<paperless-hostname>
# Should reach the k3s paperless via: nginx → Traefik → paperless-webserver
```

### Rollback (if anything is wrong)

```bash
# Revert proxy_pass to localhost:<docker-port> and reload:
ssh raspberrypi "sudo nginx -s reload"
# Docker Paperless is immediately active again
```

---

## Phase 6 — Cleanup

After a few days of stable operation:

```bash
# Stop Docker containers (not down — keeps volumes as fallback)
ssh raspberrypi "cd ~/docker/paperless && docker compose stop"
# After confirmed working (weeks):
ssh raspberrypi "cd ~/docker/paperless && docker compose down"
```

Backup integration — add to `scripts/backup.sh` on the k3s node:
- `pg_dump` for PostgreSQL (`paperless-db` pod)
- Restic backup of the `paperless-data` and `paperless-media` PVC paths

See [Adding a new service](../operations/backup-restore.md#adding-a-new-service) in the backup docs.

Then:
- Remove this migration document
- Create clean `docs/services/paperless.md` (operational reference, no migration steps)
- Commit
