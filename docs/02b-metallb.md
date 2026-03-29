# 02b — MetalLB einrichten

Voraussetzung: [02 — k3s installieren](./02-k3s-install.md) abgeschlossen.

MetalLB ist ein Load Balancer für Bare-Metal-Kubernetes. k3s bringt einen eingebauten LoadBalancer (Klipper/ServiceLB) mit, der Services einfach an die Node-IP bindet. MetalLB ersetzt Klipper und weist stattdessen dedizierte virtuelle IPs (VIPs) zu — stabil, unabhängig von der Node-IP, und bei Multi-Node failover-fähig.

**Wann wird MetalLB gebraucht?**
Immer wenn ein Service nicht über HTTP/HTTPS läuft und deshalb nicht durch Traefik geroutet werden kann. Pi-hole DNS (Port 53) ist der erste solche Service.

---

## Schritt 1 — k3s ServiceLB deaktivieren

k3s und MetalLB können nicht gleichzeitig laufen — beide würden versuchen LoadBalancer-Services zu bedienen.

Auf dem k3s-Node:
```bash
sudo nano /etc/rancher/k3s/config.yaml
```

Folgenden Block ergänzen (oder `disable`-Liste erweitern falls bereits vorhanden):
```yaml
disable:
  - servicelb
```

k3s neu starten:
```bash
sudo systemctl restart k3s
```

Prüfen ob Klipper-Pods weg sind:
```bash
kubectl get pods -n kube-system | grep svclb
# → keine Ausgabe mehr
```

---

## Schritt 2 — MetalLB Controller installieren

```bash
# Aktuelle Version prüfen: https://github.com/metallb/metallb/releases
METALLB_VERSION="v0.14.9"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml
```

Warten bis MetalLB bereit ist:
```bash
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

> **GitOps-Hinweis:** Das Laden des Manifests direkt aus dem Internet ist für den manuellen Setup pragmatisch. Sobald Flux CD eingerichtet ist, gehört das Manifest ins Repo (`infrastructure/metallb/controller.yaml`).

---

## Schritt 3 — IP-Pool konfigurieren

```bash
kubectl apply -f infrastructure/metallb/metallb.yaml
```

Prüfen ob Pool und Advertisement angelegt wurden:
```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

## Schritt 4 — Verifizieren

Einen bestehenden LoadBalancer-Service prüfen (z.B. Pi-hole):
```bash
kubectl get svc -n pihole pihole-dns
# → EXTERNAL-IP sollte jetzt eine IP aus 192.168.178.201-220 zeigen
# → nicht mehr die Node-IP 192.168.178.171
```

Falls der Service vorher schon lief (mit Klipper), bekommt er nach MetalLB-Installation automatisch eine neue VIP aus dem Pool zugewiesen.

---

## IP-Pool Übersicht

| Bereich | Zweck |
|---|---|
| `192.168.178.1-200` | Fritz!Box DHCP — nicht anfassen |
| `192.168.178.201-220` | MetalLB Pool — dedizierte Service-VIPs |
| `fd9d:c2c4:babc::201-::220` | MetalLB Pool IPv6 |

Vergebene VIPs:
| Service | IPv4 | IPv6 |
|---|---|---|
| Pi-hole DNS | 192.168.178.201 | fd9d:c2c4:babc::201 |

> Diese Tabelle manuell aktuell halten wenn neue LoadBalancer-Services hinzukommen.

---

## Weiter: [04b — Pi-hole deployen](./04b-pihole.md)
