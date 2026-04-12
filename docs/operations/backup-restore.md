# Backup & Restore

## Overview

Unified backup strategy via Restic for all services:

| Strategy | Tool | Services | Restore granularity |
|---|---|---|---|
| File backup | Restic → Hetzner S3 | All services | individual files, entire service |

`local-path` volumes live directly on the node filesystem (`/var/lib/rancher/k3s/storage/<pvc-name>/`) — Restic can back them up directly without a snapshot mechanism.

---

## Critical secrets outside the cluster

These values **cannot** be recovered from the cluster if etcd is gone. Store them in the password manager — independent of cluster state:

| Secret | Where to find it | Where to store |
|---|---|---|
| SOPS age private key | `~/.config/sops/age/keys.txt` on the laptop | Vaultwarden |
| Hetzner S3 credentials | Hetzner Console | Vaultwarden |
| Restic repo password (S3) | from `.restic.env` | Vaultwarden |

> The age private key is the only secret that cannot be recovered from the cluster or from Git. Keep it in Vaultwarden. **Never commit it.**

---

## Restic Backup (all services)

### How it works

The backup script runs as a cron job directly on the Pi node and:
1. Connects via `kubectl exec` to the database pod and creates a `pg_dumpall` dump
2. Copies application data via `kubectl cp` from the app pod
3. Backs everything up with Restic to the Hetzner S3 bucket
4. Reports status per service via MQTT to Home Assistant

Each service gets its own HA sensor (`backup_paperless`, `backup_teslamate`, `backup_overall`).

### Setup

**Prerequisite:** Hetzner S3 bucket exists (create manually in the Hetzner Cloud Console).

**Install Restic on the Pi node:**

```bash
# Check current version: https://github.com/restic/restic/releases
RESTIC_VERSION="0.17.3"
wget "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_arm64.bz2"
bunzip2 "restic_${RESTIC_VERSION}_linux_arm64.bz2"
sudo mv "restic_${RESTIC_VERSION}_linux_arm64" /usr/local/bin/restic
sudo chmod +x /usr/local/bin/restic
restic version
```

**Install mosquitto-clients** (for MQTT notifications):

```bash
sudo apt install mosquitto-clients
```

**Set up the script:**

```bash
cd ~/workspace/priv/k3s/scripts

cp backup.sh.example backup.sh
chmod 700 backup.sh

cp .restic.env.example .restic.env
chmod 600 .restic.env
# Fill in .restic.env with your values

cp .mqtt_credentials.example .mqtt_credentials
chmod 600 .mqtt_credentials
# Fill in .mqtt_credentials with MQTT_USER and MQTT_PASSWORD
```

**Initialise Restic S3 repo** (once):

```bash
source .restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" init
```

**Set up cron job:**

```bash
crontab -e
```

Entry:
```
30 2 * * * /home/<your-user>/k3s/scripts/backup.sh >> /var/log/k3s-backup.log 2>&1
```

**Test the first backup run:**

```bash
~/workspace/priv/k3s/scripts/backup.sh
```

Verify snapshots exist:
```bash
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots
```

### Adding a new service

When another service is migrated to k3s:
1. Add the service to `BACKUP_SERVICES` in `scripts/.restic.env`
2. Add a `backup_<service>()` function in `scripts/backup.sh` (analogous to `backup_paperless`)
3. Register the function in the `case` block below

### Home Assistant dashboard

A sensor for each service and the overall status appears automatically in HA (via MQTT Discovery). Example card for the dashboard:

```yaml
type: entities
title: Restic Backup
entities:
  - entity: sensor.backup_overall
  - entity: sensor.backup_paperless
  - entity: sensor.backup_teslamate
```

---

## Restore — Restic

### List available snapshots

```bash
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots
```

Filter by service:
```bash
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --tag paperless
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --tag teslamate
```

### Restore a single file / directory

```bash
# Get snapshot ID from `restic snapshots`, e.g. abc12345
SNAPSHOT="abc12345"

# List contents of a snapshot
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  ls "$SNAPSHOT"

# Restore a single file / directory to /tmp
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore "$SNAPSHOT" \
  --include "/tmp/k3s-backup/paperless/media/documents/originals/2025/01/invoice.pdf" \
  --target /tmp/restore
```

### Restore an entire service (cluster running)

**Step 1 — Restore staging directory from Restic:**

```bash
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest \
  --tag paperless \
  --target /tmp/restore
```

The staging directory is at `/tmp/restore/tmp/k3s-backup/paperless/`.

**Step 2 — Import DB dump into the running DB pod:**

```bash
# Stop service (prevents write conflicts during restore)
kubectl scale deployment paperless -n paperless --replicas=0
kubectl scale deployment paperless-db -n paperless --replicas=0

# Wait until pods are gone
kubectl wait --for=delete pod -n paperless -l app=paperless --timeout=60s

# Start DB pod again (without app)
kubectl scale deployment paperless-db -n paperless --replicas=1
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless-db --timeout=60s

# Import dump
DB_POD=$(kubectl get pod -n paperless -l app=paperless-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/restore/tmp/k3s-backup/paperless/paperless_db_*.sql.gz \
  | kubectl exec -i -n paperless "$DB_POD" -- psql -U paperless
```

**Step 3 — Copy media files back:**

```bash
# Start app pod
kubectl scale deployment paperless -n paperless --replicas=1
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless --timeout=90s

APP_POD=$(kubectl get pod -n paperless -l app=paperless -o jsonpath='{.items[0].metadata.name}')

# Copy media directory back
kubectl cp /tmp/restore/tmp/k3s-backup/paperless/media \
  "paperless/$APP_POD:/usr/src/paperless/media"
```

**Step 4 — Verify:**

Check documents and tags in the Paperless UI.

```bash
# Clean up
rm -rf /tmp/restore
```

### Restore an entire service (after cluster reinstall)

First complete the [SOPS recovery](../platform/sops.md#recovery-after-cluster-reinstall) (Flux bootstrap + age key import), then Restic restore as above (Steps 1-4).

---

## Restore — Restic (FreshRSS, Pi-hole)

FreshRSS and Pi-hole have no database process — their data is configuration files on the local-path volume. Restore follows the same Restic restore process as above, analogous to Paperless.

### Restore FreshRSS (cluster running)

```bash
# 1. Stop deployment
kubectl scale deployment freshrss -n freshrss --replicas=0

# 2. Restore Restic snapshot
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest --tag freshrss --target /tmp/restore

# 3. Copy data back
kubectl cp /tmp/restore/var/lib/rancher/k3s/storage/freshrss-config/. \
  freshrss/$(kubectl get pod -n freshrss -l app=freshrss -o jsonpath='{.items[0].metadata.name}'):/config/

# 4. Start deployment and verify
kubectl scale deployment freshrss -n freshrss --replicas=1
rm -rf /tmp/restore
```

### After cluster reinstall

First complete the [SOPS recovery](../platform/sops.md#recovery-after-cluster-reinstall), then Restic restore as above.

---

## Before a cluster rebuild

Checklist before tearing down the cluster:

```bash
# 1. Restic: check last successful backup run
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --last

# 2. Verify age private key is backed up in Vaultwarden
# (the key lives at ~/.config/sops/age/keys.txt on the laptop)
# If in doubt: retrieve from Vaultwarden before proceeding
```

---

## Troubleshooting

```bash
# Restic: show snapshot details
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --verbose

# Restic: check repository integrity
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" check

# Restic: remove stale locks (after aborted backup)
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" unlock

# kubectl exec not working?
#   → kubectl must be reachable on the node as the cron user
#   → check KUBECONFIG: echo $KUBECONFIG (or default /etc/rancher/k3s/k3s.yaml)
kubectl get pods -n paperless

# View backup log
tail -100 /var/log/k3s-backup.log
```

