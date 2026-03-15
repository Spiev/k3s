# 06 — Monitoring

Voraussetzung: [03 — Longhorn Storage](./03-longhorn.md) abgeschlossen, Cluster läuft stabil.

Der Standard-Stack für Kubernetes-Monitoring: **Prometheus + Grafana + Alertmanager**, installiert über das **kube-prometheus-stack** Helm-Chart.

```
Node Exporter        → Metriken vom Raspi-Host (CPU, RAM, Disk, Temperatur)
kube-state-metrics   → Metriken über K8s-Objekte (Pods, Deployments, PVCs)
Prometheus           → sammelt und speichert alle Metriken (Zeitreihendatenbank)
Alertmanager         → verarbeitet Alerts von Prometheus
Grafana              → Dashboards und Visualisierung
```

---

## 1. Helm installieren

Helm ist der Paketmanager für Kubernetes — ähnlich wie `apt` für Debian.

```bash
# Arch Linux (Laptop)
sudo pacman -S helm

# Auf dem Raspi (falls Helm dort gebraucht wird)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## 2. kube-prometheus-stack installieren

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

## 3. Grafana aufrufen

Port-Forward für den ersten Zugriff:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Browser: `http://localhost:3000`

- Benutzername: `admin`
- Passwort: das bei der Installation gesetzte Passwort

Von einem anderen Rechner im Netzwerk:
```bash
ssh -L 3000:localhost:3000 stefan@k3s.fritz.box
# Dann: http://localhost:3000 im Browser auf dem Laptop
```

> Später wird Grafana über Traefik dauerhaft erreichbar gemacht (mit Auth). Für jetzt reicht Port-Forward.

---

## 4. Vorgefertigte Dashboards

kube-prometheus-stack liefert viele Dashboards out-of-the-box. Die wichtigsten für dieses Setup:

| Dashboard | Inhalt |
|---|---|
| **Kubernetes / Nodes** | CPU, RAM, Disk, Netzwerk pro Node |
| **Kubernetes / Pods** | Ressourcenverbrauch pro Pod |
| **Kubernetes / Persistent Volumes** | PVC-Status und Speichernutzung |
| **Node Exporter Full** | Detaillierte Host-Metriken inkl. Temperatur |

Raspberry Pi CPU-Temperatur ist unter **Node Exporter Full → Hardware → Thermal** zu finden (`node_thermal_zone_temp`).

---

## 5. Persistenz konfigurieren

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

## 6. Integration mit Home Assistant (optional)

Home Assistant kann Prometheus-Metriken lesen und z.B. für Automationen nutzen (Benachrichtigung bei hoher CPU-Temperatur o.ä.).

In der HA `configuration.yaml`:

```yaml
prometheus:
  host: <raspi-ip>
  port: 9090
```

Oder umgekehrt: Prometheus scrapt den HA-eigenen `/api/prometheus`-Endpunkt und bringt HA-Sensoren in Grafana-Dashboards.

> Für den Alltag reicht Grafana als primäres Monitoring-Tool — die HA-Integration ist nice-to-have.

---

## 7. Abschluss-Check

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

## Weiter: [07 — Traefik & Ingress](./07-traefik.md)
