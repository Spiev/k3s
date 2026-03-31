# 02b — MetalLB einrichten

Voraussetzung: [02 — k3s installieren](./02-k3s-install.md) abgeschlossen.

MetalLB ist ein Load Balancer für Bare-Metal-Kubernetes. k3s bringt einen eingebauten LoadBalancer (Klipper/ServiceLB) mit, der Services einfach an die Node-IP bindet. MetalLB ersetzt Klipper und weist stattdessen dedizierte virtuelle IPs (VIPs) zu — stabil, unabhängig von der Node-IP, und bei Multi-Node failover-fähig.

**Wann wird MetalLB gebraucht?**
Immer wenn ein Service nicht über HTTP/HTTPS läuft und deshalb nicht durch Traefik geroutet werden kann. Pi-hole DNS (Port 53) ist der erste solche Service.

> [!WARNING]
> **MetalLB funktioniert nur mit Ethernet — nicht über WLAN.**
>
> MetalLB im Layer-2-Modus nutzt ARP (IPv4) bzw. NDP (IPv6) um VIPs im Netzwerk bekannt zu machen. Die meisten WLAN-Access-Points und Router leiten ARP-Announcements zwischen WLAN-Clients nicht weiter — die VIP ist dann im Netzwerk schlicht nicht erreichbar.
>
> Symptome: `kubectl get svc` zeigt eine EXTERNAL-IP, aber Verbindungen zu dieser IP hängen (Timeout). `curl <VIP>` hängt bei "Trying...".
>
> **Klipper/ServiceLB** (der k3s-Standard) bindet Ports direkt auf allen Node-Interfaces (inkl. WLAN) und ist für WLAN-Setups die richtige Wahl. MetalLB erst einrichten wenn der Node per Ethernet angebunden ist.
>
> Weitere Details: [metallb.universe.tf — Layer 2 Limitations](https://metallb.universe.tf/concepts/layer2/#limitations)

---

## Schritt 1 — k3s ServiceLB deaktivieren

k3s und MetalLB können nicht gleichzeitig laufen — beide würden versuchen LoadBalancer-Services zu bedienen.

Auf dem k3s-Node:
```bash
sudo vim /etc/rancher/k3s/config.yaml
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

Vor dem Apply `infrastructure/metallb/metallb.yaml` anpassen — Platzhalter durch die eigenen Werte ersetzen:

| Platzhalter | Bedeutung | Beispiel |
|---|---|---|
| `<METALLB-IPV4-START>` | Erste freie IP außerhalb DHCP-Bereich | erste IP nach DHCP-Ende |
| `<METALLB-IPV4-END>` | Letzte IP des Pools | +19 IPs |
| `<ULA-PREFIX>` | ULA-Prefix der Fritz!Box (ohne `::`) | aus Fritz!Box Netzwerk-Einstellungen |

```bash
kubectl apply -f infrastructure/metallb/metallb.yaml
```

Prüfen ob Pool und Advertisement angelegt wurden:
```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

## Schritt 4 — UFW für externe Services öffnen

MetalLB weist VIPs zu, aber UFW (Firewall auf dem Node) blockiert eingehenden Traffic standardmäßig. Für jeden Service der extern erreichbar sein muss, eine UFW-Regel hinzufügen.

Beispiel Pi-hole DNS (Port 53):
```bash
sudo ufw allow from <HEIMNETZ-SUBNET> to any port 53
sudo ufw allow from <ULA-PREFIX>::/64 to any port 53
```

> Nicht `ufw allow 53` ohne Quell-Einschränkung — das öffnet den Port für das gesamte Internet.

---

## Schritt 5 — Verifizieren

Einen bestehenden LoadBalancer-Service prüfen (z.B. Pi-hole):
```bash
kubectl get svc -n pihole pihole-dns
# → EXTERNAL-IP sollte jetzt eine IP aus dem konfigurierten Pool zeigen
# → nicht mehr die Node-IP
```

Falls der Service vorher schon lief (mit Klipper), bekommt er nach MetalLB-Installation automatisch eine neue VIP aus dem Pool zugewiesen.

---

## Bekannte Einschränkung: MetalLB Layer 2 + WLAN

MetalLB Layer 2 Modus kündigt VIPs per **Gratuitous ARP** (IPv4) und **NDP** (IPv6) an. Über WLAN blockiert der Fritz!Box-AP diese Ankündigungen für IPs außerhalb des DHCP-Bereichs — die VIP ist zwar zugewiesen, aber nicht erreichbar.

**Workaround für WLAN-Betrieb:**

`hostNetwork: true` im Deployment — der Pod bindet direkt auf alle Node-Interfaces (wie Docker `network_mode: host`). Der Service ist dann über die Node-IP erreichbar, nicht über die MetalLB-VIP.

```yaml
spec:
  template:
    spec:
      hostNetwork: true   # Entfernen sobald Ethernet verfügbar
```

**Sobald Ethernet angeschlossen:**
1. `hostNetwork: true` aus dem Deployment entfernen
2. `kubectl apply -f apps/<service>/<service>.yaml`
3. Fritz!Box DNS von Node-IP auf MetalLB-VIP umstellen

---

## IP-Pool Übersicht

Eine Tabelle der vergebenen VIPs hilft den Überblick zu behalten:

| Service | IPv4 VIP | IPv6 VIP |
|---|---|---|
| Pi-hole DNS | `<erste IP aus Pool>` | `<erste IPv6 aus Pool>` |

> Diese Tabelle manuell aktuell halten wenn neue LoadBalancer-Services hinzukommen.

---

## Weiter: [04b — Pi-hole deployen](./04b-pihole.md)
