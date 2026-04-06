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

| Sensor | Source | HA entity |
|---|---|---|
| CPU Usage | `/proc/stat` | `sensor.cpu_usage` |
| RAM Usage | `/proc/meminfo` | `sensor.ram_usage` |
| NVMe Disk Usage | `df /` | `sensor.nvme_usage` |
| CPU Temperature | `hwmon` (`cpu_thermal`) | `sensor.cpu_temperature` |
| NVMe Temperature | `hwmon` (`nvme`) | `sensor.nvme_temperature` |
| Fan RPM | `hwmon` (`pwmfan/fan1_input`) | `sensor.fan_speed` |
| Fan PWM | `hwmon` (`pwmfan/pwm1`) | `sensor.fan_pwm` |
| Undervoltage | `hwmon` (`rpi_volt`) | `binary_sensor.k3s_undervoltage` |

**k3s cluster status:**

| Sensor | Source | HA entity |
|---|---|---|
| Node Ready | `kubectl get nodes` | `binary_sensor.k3s_node_ready` |
| Unhealthy Pods | `kubectl get pods -A` | `sensor.k3s_unhealthy_pods` |
| Unbound PVCs | `kubectl get pvc -A` | `sensor.k3s_unbound_pvcs` |

> hwmon paths (`hwmon0`, `hwmon1` etc.) are resolved dynamically by name — no hardcoding, stays stable across reboots.

### Prerequisites

```bash
# On the k3s server node
sudo apt install -y mosquitto-clients
```

`kubectl` is already present, kubeconfig is at `~/.kube/config`.

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
*/5 * * * * /home/stefan/k3s/scripts/k3s-monitor.sh >> /home/stefan/logs/k3s-monitor.log 2>&1
```

Create the log directory if needed:

```bash
mkdir -p ~/logs
```

### Result in Home Assistant

After the first run, the device **"k3s Server Node"** appears automatically in HA (MQTT Discovery). All sensors are immediately available — no manual setup needed.

Recommended HA automations:
- Notification when `binary_sensor.k3s_node_ready` switches to `OFF`
- Notification when `sensor.k3s_unhealthy_pods` > 0
- Notification when `binary_sensor.k3s_undervoltage` = `ON`
- Warning when CPU temperature > 75 °C or NVMe temperature > 60 °C

---

## 2. kube-prometheus-stack (optional/exploratory)

The standard Kubernetes monitoring stack: **Prometheus + Grafana + Alertmanager**, installed via the **kube-prometheus-stack** Helm chart.

```
Node Exporter        → metrics from the Raspi host (CPU, RAM, disk, temperature)
kube-state-metrics   → metrics about K8s objects (pods, deployments, PVCs)
Prometheus           → collects and stores all metrics (time-series database)
Alertmanager         → processes alerts from Prometheus
Grafana              → dashboards and visualisation
```

### 2.1 Install Helm

Helm is the package manager for Kubernetes — similar to `apt` for Debian.

```bash
# Arch Linux (laptop)
sudo pacman -S helm

# On the Raspi (if Helm is needed there)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

### 2.2 Install kube-prometheus-stack

```bash
# Add Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install stack in the monitoring namespace
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=<set-password>
```

Installation takes 2–3 minutes. Monitor progress:

```bash
kubectl get pods -n monitoring -w
# All pods must reach Running
```

What gets installed:

| Pod | Function |
|---|---|
| `prometheus-*` | Metrics database |
| `grafana-*` | Dashboard UI |
| `alertmanager-*` | Alert processing |
| `node-exporter-*` (DaemonSet) | Host metrics per node |
| `kube-state-metrics-*` | K8s object metrics |

---

### 2.3 Access Grafana

Port-forward for first access:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Browser: `http://localhost:3000`

- Username: `admin`
- Password: the password set during installation

From another machine on the network:
```bash
ssh -L 3000:localhost:3000 <user>@<raspi-hostname>
# Then: http://localhost:3000 in the browser on the laptop
```

> Grafana will later be made permanently accessible via Traefik (with auth). Port-forward is sufficient for now.

---

### 2.4 Pre-built dashboards

kube-prometheus-stack ships many dashboards out of the box. The most relevant for this setup:

| Dashboard | Content |
|---|---|
| **Kubernetes / Nodes** | CPU, RAM, disk, network per node |
| **Kubernetes / Pods** | Resource usage per pod |
| **Kubernetes / Persistent Volumes** | PVC status and storage usage |
| **Node Exporter Full** | Detailed host metrics including temperature |

Raspberry Pi CPU temperature is found under **Node Exporter Full → Hardware → Thermal** (`node_thermal_zone_temp`).

---

### 2.5 Configure persistence

By default Prometheus stores metrics only in memory — they are gone after a pod restart. Persistence is configured via a Helm values file (all settings for Prometheus, Grafana, and Alertmanager in one place):

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values infrastructure/monitoring/values.yaml
```

The values file `infrastructure/monitoring/values.yaml` configures:
- Prometheus: 10 Gi, `local-path`, 30 days retention
- Grafana: 2 Gi, `local-path`
- Alertmanager: 1 Gi, `local-path`

local-path provisions the PVCs automatically — no separate PVC YAML needed.

---

### 2.6 Final check

```bash
# All monitoring pods running
kubectl get pods -n monitoring

# Prometheus Targets — are all metrics being scraped?
# Port-forward to Prometheus:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Browser: http://localhost:9090/targets → all targets should be "UP"

# Grafana reachable
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Browser: http://localhost:3000 → dashboards present
```

---

## Next: [Backup & Restore](./backup-restore.md)
