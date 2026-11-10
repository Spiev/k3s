# Monitoring

Prerequisite: cluster is running stably.

## Strategy

**Primary: Home Assistant integration** — the most important node and cluster metrics are pushed into HA via an MQTT script. HA serves as the central dashboard for smart home and infrastructure.

**Secondary: kube-prometheus-stack** — the full Prometheus/Grafana/Alertmanager stack for deep, per-pod/historical Kubernetes metrics (bottleneck detection), running permanently alongside the HA/MQTT layer. See [Decision: Cluster Monitoring](../decisions/cluster-monitoring.md) for placement, resource-limit, exposure and alerting decisions.

---

## 1. Home Assistant integration via MQTT

The script `scripts/k3s-monitor.sh` runs on the k3s server node, collects metrics, and pushes them via MQTT Discovery to Home Assistant — exactly like the existing `check_raspi_update.sh` on the Docker host.

### What is monitored

**Node metrics (Linux):**

| Sensor | Source |
|---|---|
| CPU Usage | `/proc/stat` |
| RAM Usage | `/proc/meminfo` |
| NVMe Disk Usage | `df /` |
| CPU Temperature | `hwmon` (`cpu_thermal`) |
| NVMe Temperature | `hwmon` (`nvme`) |
| Fan RPM | `hwmon` (`pwmfan/fan1_input`) |
| Fan PWM | `hwmon` (`pwmfan/pwm1`) |
| Undervoltage | `hwmon` (`rpi_volt`) |
| System Updates | `apt update` (cached 1 h) |
| EEPROM Status | `rpi-eeprom-update` |

**k3s cluster status:**

| Sensor | Source |
|---|---|
| Node Ready | `kubectl get nodes` |
| Unhealthy Pods | `kubectl get pods -A` |
| Unbound PVCs | `kubectl get pvc -A` |

**Flux CD:**

| Sensor | Source |
|---|---|
| Flux Ready | all kustomizations Ready? (problem class: ON = Problem) |
| Flux Git Revision | SHA Flux fetched from GitHub (`GitRepository status.artifact.revision`) |
| Flux Applied Revision | SHA last applied to the cluster (`Kustomization apps status.lastAppliedRevision`) |
| Flux Git Fetched At | When Flux last fetched from GitHub (`GitRepository status.artifact.lastUpdateTime`) |

> When `Flux Git Revision == Flux Applied Revision`, the cluster is fully up to date with the latest commit.

> All sensors are grouped under the **k3s Server Node** device in HA (Settings → Devices & Services → MQTT → k3s Server Node). Entity IDs are not predictable — look them up there.

> hwmon paths (`hwmon0`, `hwmon1` etc.) are resolved dynamically by name — no hardcoding, stays stable across reboots.

### Prerequisites

```bash
# On the k3s server node
sudo apt install -y mosquitto-clients
```

`kubectl` is already present, kubeconfig is at `~/.kube/config`.

The `System Updates` and `EEPROM Status` sensors require passwordless `sudo` for two commands:

```bash
sudo visudo -f /etc/sudoers.d/k3s-monitor
```

```
stefan ALL=(ALL) NOPASSWD: /usr/bin/apt update
stefan ALL=(ALL) NOPASSWD: /usr/bin/rpi-eeprom-update
```

> `apt update` results are cached in `scripts/.apt_updates_cache` for 1 hour — so only one `apt update` per hour despite the 5-minute cron interval.

### Setup

```bash
# 1. Create credentials & environment config
cp scripts/.mqtt_credentials.example scripts/.mqtt_credentials
chmod 600 scripts/.mqtt_credentials
# Fill in MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASSWORD
# (MQTT_HOST = hostname of the Mosquitto broker, credentials like check_raspi_update.sh)

# 2. Make script executable
chmod +x scripts/k3s-monitor.sh

# 3. Test once
bash scripts/k3s-monitor.sh
# Check output — all values should be plausible
# In HA: Settings → Devices & Services → MQTT → "k3s Server Node" appears automatically
```

### Set up cron

```bash
crontab -e
```

```
*/5 * * * * /home/<your-user>/k3s/scripts/k3s-monitor.sh >> /home/<your-user>/logs/k3s-monitor.log 2>&1
```

Create the log directory if needed:

```bash
mkdir -p ~/logs
```

### Result in Home Assistant

After the first run, the device **"k3s Server Node"** appears automatically in HA (MQTT Discovery). All sensors are immediately available — no manual setup needed.

> **Entity naming:** HA derives entity IDs from the `object_id` in the discovery config, sometimes prefixed with the device name (e.g. `sensor.k3s_server_node_flux_ready`) and sometimes not (e.g. `sensor.k3s_fan_pwm`). All entities end up grouped under the **k3s Server Node** device regardless. Look up the actual entity ID in Settings → Devices & Services → MQTT → k3s Server Node.

> **After adding new sensors:** HA only processes retained MQTT discovery messages on connect. If a new sensor doesn't appear after running the script, reload the MQTT integration: Settings → Devices & Services → MQTT → ⋮ → Reload.

Recommended HA automations:
- Notification when `binary_sensor.k3s_node_ready` switches to `OFF`
- Notification when `sensor.k3s_unhealthy_pods` > 0
- Notification when `binary_sensor.k3s_undervoltage` = `ON`
- Warning when CPU temperature > 75 °C or NVMe temperature > 60 °C

---

## 2. kube-prometheus-stack

The standard Kubernetes monitoring stack: **Prometheus + Grafana + Alertmanager**, installed via Helm for deep, per-pod/historical Kubernetes metrics and bottleneck detection. See [Decision: Cluster Monitoring](../decisions/cluster-monitoring.md) for the full rationale and the placement/limits/exposure/alerting design.

```bash
# Setup (one-time, see docs/decisions/cluster-monitoring.md for the full rationale):
cp infrastructure/monitoring/grafana-admin-secret.yaml.example infrastructure/monitoring/grafana-admin-secret.sops.yaml
#   fill in admin-password, then: sops --encrypt --in-place infrastructure/monitoring/grafana-admin-secret.sops.yaml
cp infrastructure/monitoring/grafana-ingress.yaml.example infrastructure/monitoring/grafana-ingress.yaml
#   set the real host, then: kubectl apply -f infrastructure/monitoring/grafana-ingress.yaml
# (both real files are gitignored — see infrastructure/monitoring/.gitignore)

git add infrastructure/monitoring/ clusters/raspi/monitoring.yaml
git commit -m "feat(monitoring): add kube-prometheus-stack via Flux HelmRelease"
git push
# Flux picks up the HelmRepository + HelmRelease automatically (interval: 10m,
# or force with: flux reconcile kustomization monitoring --with-source)

# Access Grafana: via the LAN-only Ingress (grafana-ingress.yaml), or for a
# quick check without DNS: kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Ships with pre-built dashboards for nodes, pods, PVCs, and host metrics (including Raspi CPU temperature via `node_thermal_zone_temp`). Placement, resource limits, exposure and alerting scope are documented in [Decision: Cluster Monitoring](../decisions/cluster-monitoring.md); the actual Helm values live in `infrastructure/monitoring/kube-prometheus-stack.yaml`.

---

## Next: [Backup & Restore](./backup-restore.md)
