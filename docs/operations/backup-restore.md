# Backup & Restore

## Overview

Unified backup strategy via Restic for all services:

| Strategy | Tool | Services | Restore granularity |
|---|---|---|---|
| DB dump + Restic → Hetzner S3 | Restic | Teslamate, Seafile, Paperless | individual files, entire service |

The backup script runs as a cron job on the k3s node. It auto-detects running services, creates DB dumps and file snapshots via `kubectl exec`, uploads them to Hetzner S3 via Restic, and reports status per service via MQTT to Home Assistant.

**Hetzner project:** `k3s-homelab` — S3 bucket: `<your-bucket-name>`

---

## Critical secrets outside the cluster

These values **cannot** be recovered from the cluster if etcd is gone. Store them in Vaultwarden — independent of cluster state:

| Secret | Where to find it | Where to store |
|---|---|---|
| SOPS age private key | `~/.config/sops/age/keys.txt` on the laptop | Vaultwarden |
| Hetzner S3 credentials | Hetzner Console → k3s-homelab project | Vaultwarden |
| Restic repo password (S3) | `~/k3s/scripts/.restic.env` on k3s node | Vaultwarden |

> The age private key is the only secret that cannot be recovered from the cluster or from Git. Keep it in Vaultwarden. **Never commit it.**

---

## Restic Backup (all services)

### How it works

The backup script (`scripts/backup.sh`) runs as a cron job on the k3s node and:
1. Auto-detects which known services have running pods
2. Creates DB dumps via `kubectl exec` into a staging directory (`BACKUP_TEMP_DIR`)
3. Reads PVC data in-place from the local-path-provisioner filesystem — no local copy needed for large volumes (e.g. Paperless media)
4. Uploads everything to Hetzner S3 via Restic (one snapshot per service, tagged)
5. Reports status per service via MQTT to Home Assistant
6. Cleans up the staging directory

Each service gets its own HA sensor (`backup_teslamate`, `backup_seafile`, `backup_paperless`, `backup_overall`).

### Setup

**Prerequisite:** Hetzner S3 bucket exists (create in Hetzner Cloud Console, project `k3s-homelab`).

**Install dependencies on the k3s node:**

```bash
sudo apt install restic bc mosquitto-clients
```

**Set up the scripts:**

```bash
cd ~/k3s/scripts

cp backup.sh.example backup.sh
chmod 700 backup.sh

cp .restic.env.example .restic.env
chmod 600 .restic.env
# Fill in: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, RESTIC_REPO_S3, RESTIC_PASSWORD_S3
# RESTIC_REPO_S3 format: s3:https://nbg1.your-objectstorage.com/YOUR_BUCKET/restic-repo

cp .mqtt.env.example .mqtt.env
chmod 600 .mqtt.env
# Fill in: MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASSWORD
```

**Initialise Restic S3 repo** (once):

```bash
cd ~/k3s/scripts
source .restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" init
```

**Set up cron job:**

```bash
crontab -e
```

```
30 2 * * * /home/stefan/k3s/scripts/backup.sh >> /home/stefan/logs/k3s-backup.log 2>&1
```

**Test:**

```bash
~/k3s/scripts/backup.sh
```

Verify snapshots:
```bash
cd ~/k3s/scripts && source .restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots
```

### Adding a new service

When another service is migrated to k3s:
1. Add the service name to `KNOWN_SERVICES` in `scripts/backup.sh.example`
2. Add a `service_display_name()` case for it
3. Add a `backup_<service>()` function (analogous to `backup_teslamate` or `backup_paperless`)
4. Add a case to the dispatch block in Main
5. Copy the updated file to `~/k3s/scripts/backup.sh` on the k3s node

The script auto-detects running services — no manual enable/disable needed after onboarding.

### Home Assistant dashboard

Sensors appear automatically via MQTT Discovery after the first backup run. Example card:

```yaml
type: entities
title: Restic Backup
entities:
  - entity: sensor.backup_overall
  - entity: sensor.backup_teslamate
  - entity: sensor.backup_seafile
  - entity: sensor.backup_paperless
```

---

## Restore — Teslamate

```bash
cd ~/k3s/scripts && source .restic.env

# 1. Restore staging directory from Restic
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest --tag teslamate --target /tmp/restore

# 2. Scale down Teslamate, drop and recreate DB
kubectl scale deployment teslamate teslamate-grafana -n teslamate --replicas=0
kubectl wait --for=delete pod -n teslamate -l app=teslamate --timeout=60s
DB_POD=$(kubectl get pod -n teslamate -l app=teslamate-db -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n teslamate "$DB_POD" -- psql -U teslamate -c "DROP DATABASE teslamate;" postgres
kubectl exec -n teslamate "$DB_POD" -- psql -U teslamate -c "CREATE DATABASE teslamate OWNER teslamate;" postgres

# 3. Import dump
zcat /tmp/restore/tmp/k3s-backup/teslamate/teslamate_db_*.sql.gz \
  | kubectl exec -i -n teslamate "$DB_POD" -- psql -U teslamate teslamate

# 4. Scale back up and verify
kubectl scale deployment teslamate teslamate-grafana -n teslamate --replicas=1
kubectl exec -n teslamate "$DB_POD" -- psql -U teslamate -c 'SELECT count(*) FROM drives;' teslamate

rm -rf /tmp/restore
```

---

## Restore — Seafile

The backup contains three MariaDB databases and the full `/shared/seafile` data directory (library blocks, commits, fs objects). Restore databases first, then file data — this is the order required by the [official Seafile backup guide](https://manual.seafile.com/latest/administration/backup_recovery/).

```bash
cd ~/k3s/scripts && source .restic.env

# 1. Restore staging directory from Restic
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest --tag seafile --target /tmp/restore

# 2. Scale down Seafile app (keep MariaDB running for import)
kubectl scale deployment seafile -n seafile --replicas=0
kubectl wait --for=delete pod -n seafile -l app=seafile --timeout=60s

# 3. Import databases (dump includes CREATE DATABASE — drop first to start clean)
DB_POD=$(kubectl get pod -n seafile -l app=mariadb -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n seafile "$DB_POD" -- \
  bash -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS ccnet_db; DROP DATABASE IF EXISTS seafile_db; DROP DATABASE IF EXISTS seahub_db;"'
zcat /tmp/restore/tmp/k3s-backup/seafile/seafile_db_*.sql.gz \
  | kubectl exec -i -n seafile "$DB_POD" -- bash -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD"'

# 4. Restore file data into the Seafile pod's /shared volume
kubectl scale deployment seafile -n seafile --replicas=1
kubectl wait --for=condition=Ready pod -n seafile -l app=seafile --timeout=90s
APP_POD=$(kubectl get pod -n seafile -l app=seafile -o jsonpath='{.items[0].metadata.name}')
tar -C /tmp/restore/tmp/k3s-backup/seafile/seafile-data -cf - seafile \
  | kubectl exec -i -n seafile "$APP_POD" -- tar -C /shared -xf -

# 5. Optional: repair any DB/file inconsistencies (safe to always run after restore)
kubectl exec -n seafile "$APP_POD" -- \
  bash -c "/opt/seafile/seafile-server-latest/seaf-fsck.sh --repair"

rm -rf /tmp/restore
```

---

## Restore — Paperless

The backup contains: a PostgreSQL dump (in `BACKUP_TEMP_DIR/paperless/`) plus the
`paperless-media` and `paperless-data` PVCs read directly from the local-path filesystem.
Restic stores all three paths in a single snapshot tagged `paperless`.

```bash
cd ~/k3s/scripts && source .restic.env

# 1. Restore snapshot (DB dump + PVC paths) to temp location
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest --tag paperless --target /tmp/restore

# 2. Scale down Paperless webserver (keep DB down too)
kubectl scale deployment paperless-webserver -n paperless --replicas=0
kubectl scale deployment paperless-db -n paperless --replicas=0
kubectl wait --for=delete pod -n paperless -l app=paperless-webserver --timeout=60s

# 3. Start DB, import dump
# Adjust the path below if BACKUP_TEMP_DIR differs from /tmp/k3s-backup
kubectl scale deployment paperless-db -n paperless --replicas=1
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless-db --timeout=60s
DB_POD=$(kubectl get pod -n paperless -l app=paperless-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/restore/tmp/k3s-backup/paperless/paperless_db_*.sql.gz \
  | kubectl exec -i -n paperless "$DB_POD" -- psql -U paperless

# 4. Restore media and data PVCs directly to the local-path storage
STORAGE="/var/lib/rancher/k3s/storage"
MEDIA_PVC=$(sudo find "$STORAGE" -maxdepth 1 -name "*_paperless_paperless-media" -type d)
DATA_PVC=$(sudo find  "$STORAGE" -maxdepth 1 -name "*_paperless_paperless-data"  -type d)
sudo rsync -a --delete "/tmp/restore${MEDIA_PVC}/" "$MEDIA_PVC/"
sudo rsync -a --delete "/tmp/restore${DATA_PVC}/"  "$DATA_PVC/"

# 5. Scale back up and verify
kubectl scale deployment paperless-webserver -n paperless --replicas=1
kubectl logs -n paperless -l app=paperless-webserver -f

rm -rf /tmp/restore
```

---

## Before a cluster rebuild

```bash
cd ~/k3s/scripts && source .restic.env

# 1. Check last successful backup
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --last

# 2. Verify age private key is in Vaultwarden
# 3. Verify Hetzner S3 credentials and Restic repo password are in Vaultwarden
```

---

## Troubleshooting

```bash
cd ~/k3s/scripts && source .restic.env

# Show snapshots
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots

# Check repository integrity
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" check

# Remove stale locks (after aborted backup)
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" unlock

# View backup log
tail -100 ~/logs/k3s-backup.log

# Symptom: "no active services" despite pods running
# Cause: kubectl not found — cron PATH only contains /usr/bin:/bin
# Fix: backup.sh must use KUBECTL="/usr/local/bin/kubectl" (already the case)
export KUBECONFIG=~/.kube/config
/usr/local/bin/kubectl get pods -A
```
