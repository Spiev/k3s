# scripts/

Operational scripts that run directly on the k3s nodes (not inside the cluster).
Credential files (`.env`, `.mqtt_credentials`) are excluded from git via `.gitignore` — only `.example` templates are tracked.

```
scripts/
  backup-agent.sh            ← Restic backup (Immich + HA) on the Agent-Node (k3s-a1)
  check_agent_update.sh      ← Report apt/EEPROM updates to HA via MQTT (k3s-a1)
  ha_dashboard_sync.sh       ← Deploy dashboard YAMLs from repo into HA PVC and reload
  k3s-monitor.sh             ← Cluster health metrics → Home Assistant via MQTT
  .mqtt_credentials.example  ← MQTT credentials template (copy to .mqtt_credentials, chmod 600)
  .restic.env.example        ← Restic + S3 credentials template (copy to .restic.env, chmod 600)
  .ha.env.example            ← HA API token template (copy to .ha.env, chmod 600)
```

## Setup (on the node)

```bash
# Clone the repo onto the node
git clone https://github.com/Spiev/k3s.git ~/k3s

# Create and fill credential files from the examples
cd ~/k3s/scripts
cp .mqtt_credentials.example .mqtt_credentials && chmod 600 .mqtt_credentials
cp .restic.env.example       .restic.env       && chmod 600 .restic.env
cp .ha.env.example           .ha.env           && chmod 600 .ha.env
# Edit each file and fill in real values

# Make scripts executable
chmod 700 backup-agent.sh check_agent_update.sh ha_dashboard_sync.sh
```

## Scripts

### backup-agent.sh

Backs up the Immich library and Home Assistant config PVCs from k3s local-path
storage to an external HDD (primary Restic repo), then optionally mirrors offsite
to Hetzner S3 via `restic copy`. Status is reported to Home Assistant via MQTT
discovery/state/attributes.

Runs daily at 03:03 (after Immich's built-in DB dump at ~02:00):

```
3 3 * * * /home/stefan/k3s/scripts/backup-agent.sh >> /home/stefan/k3s/logs/backup-agent.log 2>&1
```

See [docs/operations/backup-restore.md](../docs/operations/backup-restore.md) for details and restore procedures.

### check_agent_update.sh

Checks for available apt package updates and EEPROM firmware updates on the node,
then reports the counts to Home Assistant via MQTT discovery.

```
0 8 * * * /home/stefan/k3s/scripts/check_agent_update.sh >> /home/stefan/k3s/logs/check_agent_update.log 2>&1
```

### ha_dashboard_sync.sh

Copies dashboard YAMLs from `apps/homeassistant/dashboards/` in this repo into
the Home Assistant config PVC and triggers a HA reload via the REST API.

Run manually after updating a dashboard:

```bash
~/k3s/scripts/ha_dashboard_sync.sh
```

Or via cron after a scheduled `git pull`:

```
0 * * * * cd ~/k3s && git pull --ff-only && ~/k3s/scripts/ha_dashboard_sync.sh >> ~/k3s/logs/ha_dashboard_sync.log 2>&1
```
