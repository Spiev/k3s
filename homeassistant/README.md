# Home Assistant

Home Assistant läuft aktuell noch als Docker-Container auf `raspberrypi` — die Migration zu k3s ist geplant (Agent-Node, `hostNetwork` + Zigbee-Dongle).

Dieser Ordner enthält HA-Konfiguration und Dashboards die zur k3s-Infrastruktur gehören — unabhängig davon ob HA selbst schon auf k3s läuft.

## Dashboards

| Datei | Inhalt |
|---|---|
| [backup-k3s.yaml](dashboards/backup-k3s.yaml) | Backup-Status für k3s-Services (Restic → Hetzner S3) |

### Dashboard importieren

In Home Assistant: **Settings → Dashboards → Add Dashboard → YAML-Modus** — Inhalt der jeweiligen Datei einfügen.

Sensoren erscheinen automatisch via MQTT Discovery nach dem ersten Backup-Lauf.
