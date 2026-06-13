# moto-tracker

Stack: **moto-tracker** (Python/FastAPI) + **PostgreSQL 16** + **Grafana**

Records motorcycle tours from Home Assistant location data, visualizes them in
Grafana, and exports GPX. App repo: [Spiev/moto-tracker](https://github.com/Spiev/moto-tracker).

---

## Stack overview

| Container | Image | Port |
|---|---|---|
| moto-tracker | `ghcr.io/spiev/moto-tracker:0.1.0` | 8080 |
| moto-tracker-db | `postgres:16-alpine` | 5432 (internal) |
| moto-tracker-grafana | `grafana/grafana:11.1.0` | 3000 |

---

## Manifest overview

```
apps/moto-tracker/
├── moto-tracker.yaml                    ← Namespace, PVCs, Deployments, Services, Grafana ConfigMaps
├── moto-tracker-secrets.sops.yaml       ← SOPS-encrypted secrets (you create this)
├── moto-tracker-secrets.sops.yaml.example
├── moto-tracker-ingress.yaml            ← .gitignore (web UI domain)
├── moto-tracker-ingress.yaml.example    ← template
├── grafana-ingress.yaml                 ← .gitignore (Grafana domain)
└── grafana-ingress.yaml.example         ← template
```

---

## Prerequisites

The container image lives in the **private** GHCR package `ghcr.io/spiev/moto-tracker`:

1. Publish it first — push a `vX.Y.Z` tag in the app repo (CI builds the multi-arch image).
2. Make the package public **or** create a pull secret and uncomment `imagePullSecrets`
   in `moto-tracker.yaml`:
   ```bash
   kubectl create secret docker-registry ghcr-pull -n moto-tracker \
     --docker-server=ghcr.io --docker-username=Spiev --docker-password=<PAT>
   ```

Home Assistant runs in Docker on the node (not in k3s), so `HA_URL` in the secret
must be the node address (e.g. `http://192.168.x.x:8123`), not a cluster service.

---

## Secrets

```bash
cp apps/moto-tracker/moto-tracker-secrets.sops.yaml.example \
   apps/moto-tracker/moto-tracker-secrets.sops.yaml
# Fill in DATABASE_PASS, HA_URL, HA_TOKEN, PUBLIC_BASE_URL, GRAFANA_ADMIN_PASSWORD

# Insert YubiKey, start pcscd
sudo systemctl start pcscd
sops --encrypt --in-place apps/moto-tracker/moto-tracker-secrets.sops.yaml
```

`PUBLIC_BASE_URL` must match the web UI domain in the ingress (used for share links).
HA token: see the app repo's `docs/ha-setup.md` (incl. high-accuracy GPS mode).

---

## Ingress setup

```bash
cp apps/moto-tracker/moto-tracker-ingress.yaml.example apps/moto-tracker/moto-tracker-ingress.yaml
cp apps/moto-tracker/grafana-ingress.yaml.example apps/moto-tracker/grafana-ingress.yaml
# Fill in domains, then:
kubectl apply -f apps/moto-tracker/moto-tracker-ingress.yaml
kubectl apply -f apps/moto-tracker/grafana-ingress.yaml
```

> Both ingress files are in `.gitignore` — do not commit.

---

## Verify

```bash
kubectl get pods -n moto-tracker

# Web UI healthy?
curl -s -o /dev/null -w "%{http_code}" http://<moto-domain>/healthz

# Grafana reachable?
curl -s -o /dev/null -w "%{http_code}" http://<grafana-domain>/api/health

# HA connection established?
kubectl logs -n moto-tracker -l app=moto-tracker | grep -i "Connected to HA"
```

On the first ride, positions stream in and a tour appears once you stop.

---

## Backup

Add `moto-tracker-db` (database `moto`) to `scripts/backup.sh` so it is included
in the daily pg_dump → Restic → Hetzner S3 run. See [Backup & Restore](../operations/backup-restore.md).
