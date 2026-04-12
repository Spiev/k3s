# Monitoring

Prerequisite: cluster is running stably.

## Strategy

**Primary: Home Assistant integration** — the most important node and cluster metrics are pushed into HA via an MQTT script. HA serves as the central dashboard for smart home and infrastructure.

**Optional/exploratory: kube-prometheus-stack** — the full Prometheus/Grafana stack for deep Kubernetes metrics. Useful for learning, but no permanent operation planned (separate stack with its own resource footprint).

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
| Flux Revision | `lastAppliedRevision` of apps kustomization |
| Flux Last Sync | `lastTransitionTime` of Ready condition |

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

## 2. kube-prometheus-stack (optional/exploratory)

The standard Kubernetes monitoring stack: **Prometheus + Grafana + Alertmanager**, installed via Helm. Useful for learning and deep Kubernetes metrics, but no permanent operation planned.

```bash
# Install Helm (Arch Linux)
sudo pacman -S helm

# Install stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=<set-password>

# Access Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Browser: http://localhost:3000 (admin / <password>)

# Configure persistence via Helm values
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --values infrastructure/monitoring/values.yaml
```

Ships with pre-built dashboards for nodes, pods, PVCs, and host metrics (including Raspi CPU temperature via `node_thermal_zone_temp`).

---

## Next: [Backup & Restore](./backup-restore.md)
