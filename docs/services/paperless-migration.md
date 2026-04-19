# Paperless-ngx Migration Plan: Docker → k3s

> **Temporary document** — remove after migration is complete, then create a clean `paperless.md` operational doc.

Source: `raspberrypi` → `~/docker/paperless/`

---

## Stack overview

| Container | Image | Stateful? |
|---|---|---|
| `db` | `postgres:18` | yes — pg_dump required |
| `broker` | `redis:8` | no — task queue, start fresh |
| `webserver` | `paperless-ngx:2.20.14` | yes — data + media volumes |
| `gotenberg` | `gotenberg:8.31` | no — stateless |
| `tika` | `apache/tika:3.2.3.0` | no — stateless |

---

## Target manifest structure

```
apps/paperless/
├── paperless.yaml                 ← Namespace, PVCs, all Deployments + Services
├── paperless-secrets.sops.yaml    ← SOPS-encrypted secrets
├── paperless-ingress.yaml         ← .gitignore (domain)
└── paperless-ingress.yaml.example ← template
```

---

## PVCs needed

| Name | Mount path | Size |
|---|---|---|
| `paperless-data` | `/usr/src/paperless/data` | 5Gi |
| `paperless-media` | `/usr/src/paperless/media` | 50Gi |
| `paperless-postgres` | `/var/lib/postgresql` | 10Gi |

Redis data is ephemeral — no PVC, `emptyDir` is sufficient.

---

## Secrets (SOPS)

The following keys go into `paperless-secrets.sops.yaml` (always `stringData`):

| Key | Source |
|---|---|
| `PAPERLESS_SECRET_KEY` | **Copy from existing `.env`** — must be identical to keep sessions valid |
| `PAPERLESS_DBPASS` | Copy from existing `.env` |
| `POSTGRES_PASSWORD` | Copy from existing `.env` |
| `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | Copy OIDC JSON from existing `.env` |

Non-sensitive config (OCR language, timezone, URL, flags) goes directly into the Deployment env vars — not in the secret.

---

## Step 1 — Create the manifest

Create `apps/paperless/paperless.yaml` with:

- **Namespace** `paperless` (label `type: service`)
- **PVCs**: `paperless-data`, `paperless-media`, `paperless-postgres` (all `local-path`)
- **Deployment: postgres** — mounts `paperless-postgres` at `/var/lib/postgresql`
- **Deployment: redis** — `emptyDir` volume, no PVC
- **Deployment: gotenberg** — stateless, no volume, include `--chromium-disable-javascript=true --chromium-allow-list=file:///tmp/.*`
- **Deployment: tika** — stateless, no volume
- **Deployment: webserver** — mounts all four volumes, all env vars, `depends` via init containers (wait for postgres + redis)
- **Services**: ClusterIP for each (postgres:5432, redis:6379, gotenberg:3000, tika:9998, webserver:8000)

---

## Step 2 — Create and encrypt the secret

```bash
cat > apps/paperless/paperless-secrets.sops.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: paperless-secrets
  namespace: paperless
  labels:
    app: paperless
    managed-by: flux
stringData:
  PAPERLESS_SECRET_KEY: "<copy from raspberrypi:~/docker/paperless/.env>"
  PAPERLESS_DBPASS: "<copy from raspberrypi:~/docker/paperless/.env>"
  POSTGRES_PASSWORD: "<copy from raspberrypi:~/docker/paperless/.env>"
  PAPERLESS_SOCIALACCOUNT_PROVIDERS: '<copy OIDC JSON from .env>'
EOF

sops --encrypt --in-place apps/paperless/paperless-secrets.sops.yaml
```

---

## Step 3 — Deploy (empty, data migration follows)

```bash
kubectl apply -f apps/paperless/paperless.yaml
kubectl apply -f apps/paperless/paperless-secrets.sops.yaml

# Wait until postgres is ready
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless-postgres --timeout=60s
```

> The webserver pod will crash-loop until data is migrated — that is expected at this stage.

---

## Step 4 — Migrate PostgreSQL

On `raspberrypi` — create a fresh dump:

```bash
ssh raspberrypi
docker exec paperless-db-1 pg_dump -U paperless paperless \
  | gzip > /tmp/paperless_$(date +%Y-%m-%d_%H_%M_%S).sql.gz
```

Import into the k3s pod:

```bash
scp raspberrypi:/tmp/paperless_<TIMESTAMP>.sql.gz /tmp/

DB_POD=$(kubectl get pod -n paperless -l app=paperless-postgres -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/paperless_<TIMESTAMP>.sql.gz \
  | kubectl exec -i -n paperless "$DB_POD" -- psql -U paperless paperless
```

---

## Step 5 — Migrate media and data directories

Scale down webserver to avoid writes during transfer:

```bash
kubectl scale deployment paperless-webserver -n paperless --replicas=0
```

Start a helper pod that mounts both PVCs:

```bash
kubectl run paperless-restore --image=alpine:3.23 --restart=Never -n paperless \
  --overrides='{
    "spec": {
      "volumes": [
        {"name": "data", "persistentVolumeClaim": {"claimName": "paperless-data"}},
        {"name": "media", "persistentVolumeClaim": {"claimName": "paperless-media"}}
      ],
      "containers": [{
        "name": "paperless-restore",
        "image": "alpine:3.23",
        "command": ["sleep", "3600"],
        "volumeMounts": [
          {"name": "data", "mountPath": "/data"},
          {"name": "media", "mountPath": "/media"}
        ]
      }]
    }
  }'

kubectl wait --for=condition=Ready pod -n paperless paperless-restore --timeout=30s
```

Copy from `raspberrypi`:

```bash
# Fetch from raspberrypi, push into cluster
rsync -av raspberrypi:~/docker/paperless/library/data/ /tmp/paperless-data/
rsync -av raspberrypi:~/docker/paperless/library/media/ /tmp/paperless-media/

kubectl cp /tmp/paperless-data/. paperless/paperless-restore:/data/
kubectl cp /tmp/paperless-media/. paperless/paperless-restore:/media/

kubectl delete pod -n paperless paperless-restore
```

Scale webserver back up:

```bash
kubectl scale deployment paperless-webserver -n paperless --replicas=1
```

---

## Step 6 — Test (port-forward, before switching)

```bash
kubectl port-forward -n paperless svc/paperless-webserver 8080:8000
```

Browser: `http://localhost:8080` → Google OIDC login should work, all documents visible.

---

## Step 7 — Set up ingress

```bash
cp apps/paperless/paperless-ingress.yaml.example apps/paperless/paperless-ingress.yaml
# Fill in domain, then:
kubectl apply -f apps/paperless/paperless-ingress.yaml
```

Update `PAPERLESS_URL` in the secret to match the new domain, re-encrypt and push.

---

## Step 8 — Stop Docker containers

Only once everything is verified:

```bash
ssh raspberrypi "cd ~/docker/paperless && docker compose stop"
# After a few days without issues:
ssh raspberrypi "cd ~/docker/paperless && docker compose down"
```

---

## Step 9 — Backup integration

Add Paperless to `scripts/backup.sh` on the k3s node:

- pg_dump for PostgreSQL
- Restic backup of the `media` and `data` PVC paths

---

## Step 10 — Cleanup

- Remove this planning document
- Create clean `docs/services/paperless.md` (operational reference, no migration steps)
- Commit
