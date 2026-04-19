# scripts/

Operational scripts that run directly on the k3s node (not inside the cluster).

```
scripts/
  backup.sh.example     ← Restic backup script template (copy to backup.sh, chmod 700)
  k3s-monitor.sh        ← Cluster health metrics → Home Assistant via MQTT
  .restic.env.example   ← Restic + S3 credentials template (copy to .restic.env, chmod 600)
  .mqtt.env.example     ← MQTT credentials template (copy to .mqtt.env, chmod 600)
```

Production scripts (`.sh`) and credential files (`.env`) are excluded from git via `.gitignore`. Only `.example` templates are tracked.

## Setup

```bash
cp scripts/backup.sh.example scripts/backup.sh && chmod 700 scripts/backup.sh
cp scripts/.restic.env.example scripts/.restic.env && chmod 600 scripts/.restic.env
cp scripts/.mqtt.env.example scripts/.mqtt.env && chmod 600 scripts/.mqtt.env
# Edit each file and fill in credentials
```

## Backup

`backup.sh` runs daily at 02:30 via cron. It dumps PostgreSQL databases for each service, then uploads encrypted snapshots to Hetzner S3 via Restic. Status is reported to Home Assistant via MQTT.

See [docs/operations/backup-restore.md](../docs/operations/backup-restore.md) for details and restore procedures.
