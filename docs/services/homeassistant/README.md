# Home Assistant

Prerequisite: [Install k3s](../../platform/k3s-install.md) completed, Agent-Node `k3s-a1` joined.

Home Assistant with Mosquitto (MQTT) and Matter-Hub, pinned to `k3s-a1` (Zigbee dongle).

---

## Manifest overview

```
apps/homeassistant/
├── homeassistant.yaml                   ← Namespace, PVCs, HA + Mosquitto + Matter-Hub
├── homeassistant-ingress.yaml           ← .gitignore (real domain)
├── homeassistant-ingress.yaml.example   ← template
├── matter-hub-env.sops.yaml.example     ← HA token for Matter-Hub (SOPS)
└── dashboards/                          ← YAML-mode Lovelace dashboards
```

| Component | Notes |
|---|---|
| Home Assistant | `hostNetwork` (LAN/mDNS, HomeKit), privileged for Zigbee dongle `/dev/ttyACM0` |
| Mosquitto | `LoadBalancer` on 1883/9001 for external MQTT clients; HA uses the in-cluster service |
| Matter-Hub | `hostNetwork`, needs HA token from SOPS secret |

---

## Configuration

HA config (`/config`: `configuration.yaml`, `automations.yaml`, `blueprints/`, …) lives on PVC `homeassistant-config`, **not in git**. Only dashboards are versioned here.

```bash
# read / back up / validate
kubectl -n homeassistant exec deploy/homeassistant -- cat /config/automations.yaml
kubectl -n homeassistant exec deploy/homeassistant -- \
  cp /config/automations.yaml /config/automations.yaml.bak.$(date +%Y%m%d-%H%M%S)
kubectl -n homeassistant exec deploy/homeassistant -- \
  python3 -m homeassistant --script check_config -c /config
```

After file changes: *Developer Tools → YAML → reload* the affected domain.

### Automation conventions

- **One owner per device class:** only one automation controls a given set of devices (e.g. thermostats). Others change **helpers** (`input_*`), never devices of another owner.
- **No automation controls another automation** (`automation.turn_on/off/trigger`) — references break silently on rename/merge.
- **Repeated logic** with different entities → blueprint (`/config/blueprints/automation/<folder>/`). Blueprints are YAML only, the UI can just import/use them.
- Before renaming/merging automations: `grep -n "automation\." /config/automations.yaml`.

---

## Use cases

| Doc | Content |
|---|---|
| [Heating](heating.md) | Desired state + reconciler: target temperature, windows, summer mode |
