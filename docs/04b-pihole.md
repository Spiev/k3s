# 04b — Pi-hole deployen

Voraussetzung: [03 — Longhorn](./03-longhorn.md) abgeschlossen, Dual-Stack-Cluster läuft (siehe [02 — k3s installieren](./02-k3s-install.md)).

Pi-hole läuft als DNS-Resolver für das gesamte Heimnetz. Da es ein Neudeploy ist (keine komplexen Daten zu migrieren), geht das Volume direkt auf `longhorn-retain-encrypted`.

> **Voraussetzung: Ethernet-Verbindung auf dem k3s-Node**
> Pi-hole ist DNS für das gesamte Heimnetz — WLAN ist dafür zu unzuverlässig. Den k3s-Node erst per Ethernet anschließen, dann mit dieser Anleitung fortfahren.

---

## Besonderheiten gegenüber FreshRSS

| Thema | Detail |
|---|---|
| Port 53 TCP+UDP | Kein HTTP-Routing — LoadBalancer direkt auf Port 53 |
| Dual-Stack DNS | Pi-hole muss auf IPv4 + IPv6 antworten |
| Statische ULA | Node braucht feste IPv6 damit DNS-IP stabil bleibt |
| `NET_ADMIN` | Capability für DNS-Listener (und optional DHCP) |
| Admin-Passwort | Aus gitignoriertem Secret-File (bis Sealed Secrets eingerichtet) |
| Custom DNS | Wenige Hostnamen — manuell übertragen |

---

## Schritt 1 — Statische ULA-Adresse auf dem k3s-Node einrichten

Der k3s-Node bekommt eine feste IPv6-Adresse aus dem ULA-Prefix der Fritz!Box (`fd9d:c2c4:babc::/64`). ULA-Adressen ändern sich nie — unabhängig vom ISP-Prefix. Der andere Raspi nutzt bereits `fd9d:c2c4:babc::53`, wir nehmen `fd9d:c2c4:babc::1` für den k3s-Node.

```bash
# Auf dem k3s-Node: aktuelle Verbindung prüfen
nmcli connection show
# → Name der aktiven Verbindung notieren (z.B. "Wired connection 1")

# Statische IPv6 zur bestehenden Verbindung hinzufügen
sudo nmcli connection modify "Wired connection 1" \
  ipv6.addresses "fd9d:c2c4:babc::1/64" \
  ipv6.method "auto"        # SLAAC bleibt aktiv, ULA wird zusätzlich gesetzt

sudo nmcli connection up "Wired connection 1"

# Prüfen
ip addr show eth0
# → fd9d:c2c4:babc::1/64 sollte erscheinen
```

> `ipv6.method auto` behält SLAAC (für globale IPv6-Erreichbarkeit) und fügt die ULA als zusätzliche Adresse hinzu. Pi-hole antwortet auf beide.

---

## Schritt 2 — Übersicht der Manifeste

```
apps/pihole/
├── pihole.yaml                  ← ins Repo (Namespace, PVC, Deployment, Services)
├── pihole-secret.yaml           ← .gitignore (WEBPASSWORD)
├── pihole-secret.yaml.example   ← ins Repo (Template)
├── pihole-ingress.yaml          ← .gitignore (Admin-UI Hostname)
└── pihole-ingress.yaml.example  ← ins Repo (Template)
```

---

## Schritt 3 — Secret für Admin-Passwort anlegen

```bash
cp apps/pihole/pihole-secret.yaml.example apps/pihole/pihole-secret.yaml
# Passwort in pihole-secret.yaml eintragen
kubectl apply -f apps/pihole/pihole-secret.yaml
```

---

## Schritt 4 — Manifeste deployen

```bash
kubectl apply -f apps/pihole/
```

Status beobachten:
```bash
kubectl get pods -n pihole -w
# Warten bis 1/1 Running

kubectl get svc -n pihole
# pihole-dns sollte EXTERNAL-IP (IPv4 + IPv6) zeigen
```

Die External-IPs des `pihole-dns`-Service notieren — werden in Schritt 6 benötigt:
```bash
kubectl get svc -n pihole pihole-dns -o wide
```

---

## Schritt 5 — Custom DNS-Einträge übertragen

Aktuelle Einträge vom alten Pi-hole exportieren:

```bash
# Auf dem alten Raspi
cat /etc/pihole/custom.list
```

In die neue Instanz eintragen:

```bash
# Auf dem k3s-Node
kubectl exec -it -n pihole deploy/pihole -- bash

# Einträge hinzufügen (Format: <IP> <Hostname>)
echo "192.168.178.113 raspberrypi.fritz.box" >> /etc/pihole/custom.list
# ... weitere Einträge

# Pi-hole neu laden
pihole restartdns
exit
```

Alternativ über die Admin-UI: **Local DNS → DNS Records**.

---

## Schritt 6 — Pi-hole testen (vor der Umstellung)

Erst testen bevor die Fritz!Box umgestellt wird:

```bash
# Vom Laptop aus: DNS-Anfrage direkt an die neue Pi-hole-IP schicken
dig @<EXTERNAL-IPv4-des-pihole-dns> google.com
dig @fd9d:c2c4:babc::1 google.com

# Custom-Hostname testen
dig @<EXTERNAL-IPv4-des-pihole-dns> raspberrypi.fritz.box
```

Beide Anfragen sollten eine Antwort liefern. Wenn ja: Pi-hole funktioniert korrekt.

---

## Schritt 7 — Fritz!Box umstellen

In der **Fritz!Box** unter Heimnetz → Netzwerk → DNS:
- DNS-Server (IPv4): `<EXTERNAL-IPv4 des pihole-dns Service>`
- DNS-Server (IPv6): `fd9d:c2c4:babc::1`

Danach DHCP-Lease auf einem Client erneuern und prüfen:
```bash
# Linux
sudo dhclient -r && sudo dhclient

# Oder einfach WLAN kurz aus/ein
```

---

## Schritt 8 — Alten Pi-hole stoppen

Erst wenn DNS auf allen Geräten korrekt funktioniert:

```bash
# Auf dem alten Raspi
cd ~/docker   # oder wo dein docker-compose.yml liegt
docker compose stop pihole
```

Den alten Pi-hole noch einige Tage laufen lassen (aber gestoppt) bevor er entfernt wird — als Fallback falls etwas nicht stimmt.

---

## Troubleshooting

```bash
# Pi-hole Pod startet nicht?
kubectl describe pod -n pihole -l app=pihole
kubectl logs -n pihole -l app=pihole

# DNS-Service hat keine External-IP?
kubectl describe svc -n pihole pihole-dns
# → Events prüfen ob klipper-lb den Port binden konnte

# Port 53 bereits belegt auf dem Node?
ssh stefan@k3s.fritz.box "sudo ss -tulpn | grep :53"
# → systemd-resolved hört auf 127.0.0.53, nicht auf dem Netzwerk-Interface → kein Konflikt

# IPv6 DNS antwortet nicht?
ssh stefan@k3s.fritz.box "ip addr show eth0 | grep fd9d"
# → ULA-Adresse muss vorhanden sein
```

---

## Weiter: [04c — Seafile deployen](./04c-seafile.md)
