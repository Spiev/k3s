# 06 — Monitoring

Voraussetzung: [03 — Longhorn Storage](./03-longhorn.md) abgeschlossen, Cluster läuft stabil.

## Strategie

**Primär: Home Assistant Integration** — die wichtigsten Node- und Cluster-Metriken werden per MQTT-Script in HA eingespeist. HA dient als zentrales Dashboard für Smarthome und Infrastruktur.

**Optional/explorativ: kube-prometheus-stack** — der vollständige Prometheus/Grafana-Stack für tiefgehende Kubernetes-Metriken. Sinnvoll zum Lernen, aber kein dauerhafter Betrieb geplant (separater Stack mit eigenem Ressourcenbedarf).

---

## 1. Home Assistant Integration via MQTT

Das Script `scripts/k3s-monitor.sh` läuft auf dem k3s Server-Node, sammelt Metriken und pusht sie via MQTT Discovery zu Home Assistant — genau wie das bestehende `check_raspi_update.sh` auf dem Docker-Host.

### Was wird gemonitort

**Node-Metriken (Linux):**

| Sensor | Quelle | HA-Entity |
|---|---|---|
| CPU Usage | `/proc/stat` | `sensor.cpu_usage` |
| RAM Usage | `/proc/meminfo` | `sensor.ram_usage` |
| NVMe Disk Usage | `df /` | `sensor.nvme_usage` |
| CPU Temperatur | `hwmon` (`cpu_thermal`) | `sensor.cpu_temperature` |
| NVMe Temperatur | `hwmon` (`nvme`) | `sensor.nvme_temperature` |
| Lüfter RPM | `hwmon` (`pwmfan/fan1_input`) | `sensor.fan_speed` |
| Lüfter PWM | `hwmon` (`pwmfan/pwm1`) | `sensor.fan_pwm` |
| Unterspannung | `hwmon` (`rpi_volt`) | `binary_sensor.k3s_undervoltage` |

**k3s Cluster-Status:**

| Sensor | Quelle | HA-Entity |
|---|---|---|
| Node Ready | `kubectl get nodes` | `binary_sensor.k3s_node_ready` |
| Unhealthy Pods | `kubectl get pods -A` | `sensor.k3s_unhealthy_pods` |
| Unbound PVCs | `kubectl get pvc -A` | `sensor.k3s_unbound_pvcs` |

> Die hwmon-Pfade (`hwmon0`, `hwmon1` etc.) werden dynamisch per Name aufgelöst — kein Hardcoding, bleibt stabil über Reboots.

### Voraussetzungen

```bash
# Auf dem k3s Server-Node
sudo apt install -y mosquitto-clients
```

`kubectl` ist bereits vorhanden, Kubeconfig liegt unter `~/.kube/config`.

### Setup

```bash
# 1. Credentials & Umgebungskonfiguration anlegen
cp scripts/.mqtt_credentials.example scripts/.mqtt_credentials
chmod 600 scripts/.mqtt_credentials
# MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASSWORD eintragen
# (MQTT_HOST = Hostname des Mosquitto-Brokers, Zugangsdaten wie check_raspi_update.sh)

# 2. Script ausführbar machen
chmod +x scripts/k3s-monitor.sh

# 3. Einmalig testen
bash scripts/k3s-monitor.sh
# Ausgabe prüfen — alle Werte sollten plausibel sein
# In HA: Einstellungen → Geräte & Dienste → MQTT → "k3s Server Node" erscheint automatisch
```

### Cron einrichten

```bash
crontab -e
```

```
*/5 * * * * /home/stefan/k3s/scripts/k3s-monitor.sh >> /home/stefan/logs/k3s-monitor.log 2>&1
```

Log-Verzeichnis anlegen falls nötig:

```bash
mkdir -p ~/logs
```

### Ergebnis in Home Assistant

Nach dem ersten Lauf erscheint automatisch das Gerät **"k3s Server Node"** in HA (MQTT Discovery). Alle Sensoren sind sofort verfügbar — kein manuelles Anlegen nötig.

Empfohlene HA-Automationen:
- Benachrichtigung wenn `binary_sensor.k3s_node_ready` auf `OFF` wechselt
- Benachrichtigung wenn `sensor.k3s_unhealthy_pods` > 0
- Benachrichtigung bei `binary_sensor.k3s_undervoltage` = `ON`
- Warnung wenn CPU-Temperatur > 75 °C oder NVMe-Temperatur > 60 °C

---

## 2. kube-prometheus-stack (optional/explorativ)

Der Standard-Stack für Kubernetes-Monitoring: **Prometheus + Grafana + Alertmanager**, installiert über das **kube-prometheus-stack** Helm-Chart.

```
Node Exporter        → Metriken vom Raspi-Host (CPU, RAM, Disk, Temperatur)
kube-state-metrics   → Metriken über K8s-Objekte (Pods, Deployments, PVCs)
Prometheus           → sammelt und speichert alle Metriken (Zeitreihendatenbank)
Alertmanager         → verarbeitet Alerts von Prometheus
Grafana              → Dashboards und Visualisierung
```

### 2.1 Helm installieren

Helm ist der Paketmanager für Kubernetes — ähnlich wie `apt` für Debian.

```bash
# Arch Linux (Laptop)
sudo pacman -S helm

# Auf dem Raspi (falls Helm dort gebraucht wird)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

### 2.2 kube-prometheus-stack installieren

```bash
# Helm-Repository hinzufügen
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Stack im Namespace monitoring installieren
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=<passwort-setzen>
```

Die Installation dauert 2–3 Minuten. Fortschritt beobachten:

```bash
kubectl get pods -n monitoring -w
# Alle Pods müssen Running erreichen
```

Was installiert wird:

| Pod | Funktion |
|---|---|
| `prometheus-*` | Metriken-Datenbank |
| `grafana-*` | Dashboard-UI |
| `alertmanager-*` | Alert-Verarbeitung |
| `node-exporter-*` (DaemonSet) | Host-Metriken je Node |
| `kube-state-metrics-*` | K8s-Objekt-Metriken |

---

### 2.3 Grafana aufrufen

Port-Forward für den ersten Zugriff:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Browser: `http://localhost:3000`

- Benutzername: `admin`
- Passwort: das bei der Installation gesetzte Passwort

Von einem anderen Rechner im Netzwerk:
```bash
ssh -L 3000:localhost:3000 <user>@<raspi-hostname>
# Dann: http://localhost:3000 im Browser auf dem Laptop
```

> Später wird Grafana über Traefik dauerhaft erreichbar gemacht (mit Auth). Für jetzt reicht Port-Forward.

---

### 2.4 Vorgefertigte Dashboards

kube-prometheus-stack liefert viele Dashboards out-of-the-box. Die wichtigsten für dieses Setup:

| Dashboard | Inhalt |
|---|---|
| **Kubernetes / Nodes** | CPU, RAM, Disk, Netzwerk pro Node |
| **Kubernetes / Pods** | Ressourcenverbrauch pro Pod |
| **Kubernetes / Persistent Volumes** | PVC-Status und Speichernutzung |
| **Node Exporter Full** | Detaillierte Host-Metriken inkl. Temperatur |

Raspberry Pi CPU-Temperatur ist unter **Node Exporter Full → Hardware → Thermal** zu finden (`node_thermal_zone_temp`).

---

### 2.5 Persistenz konfigurieren

Standardmäßig speichert Prometheus Metriken nur im Arbeitsspeicher — nach einem Pod-Neustart sind sie weg. Persistenz wird über eine Helm-Values-Datei konfiguriert (alle Einstellungen für Prometheus, Grafana und Alertmanager gebündelt):

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values infrastructure/monitoring/values.yaml
```

Die Values-Datei `infrastructure/monitoring/values.yaml` konfiguriert:
- Prometheus: 10 Gi, `longhorn-retain`, 30 Tage Retention
- Grafana: 2 Gi, `longhorn-retain`
- Alertmanager: 1 Gi, `longhorn-retain`

Longhorn legt die PVCs automatisch an — keine separate PVC-YAML nötig.

---

### 2.6 Abschluss-Check

```bash
# Alle Monitoring-Pods laufen
kubectl get pods -n monitoring

# Prometheus Targets — werden alle Metriken gescrapt?
# Port-Forward auf Prometheus:
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Browser: http://localhost:9090/targets → alle Targets sollten "UP" sein

# Grafana erreichbar
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Browser: http://localhost:3000 → Dashboards vorhanden
```

---

## Weiter: [09 — Backup & Restore](./09-backup-restore.md)
