# 04b — Pi-hole deployen

Voraussetzung: [03 — Longhorn](./03-longhorn.md) abgeschlossen, [04e — Sealed Secrets](./04e-sealed-secrets.md) eingerichtet, Dual-Stack-Cluster läuft (siehe [02 — k3s installieren](./02-k3s-install.md)).

Pi-hole läuft als DNS-Resolver für das gesamte Heimnetz. Da es ein Neudeploy ist (keine komplexen Daten zu migrieren), geht das Volume direkt auf `longhorn-retain-encrypted`.

> **Hinweis: Netzwerkverbindung**
> Pi-hole ist DNS für das gesamte Heimnetz. WLAN funktioniert für den Einstieg, solange die Verbindung stabil ist. Ethernet ist empfohlen für dauerhaften Produktionsbetrieb — kann jederzeit nachgerüstet werden ohne Pi-hole neu deployen zu müssen.

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
# Auf dem k3s-Node: aktive Verbindung und Interface ermitteln
nmcli connection show --active
# → Name und DEVICE notieren (z.B. "preconfigured" / wlan0, oder "Wired connection 1" / eth0)

# Statische IPv6 zur aktiven Verbindung hinzufügen (Connection-Name anpassen)
sudo nmcli connection modify "preconfigured" \
  ipv6.addresses "fd9d:c2c4:babc::1/64" \
  ipv6.method "auto"        # SLAAC bleibt aktiv, ULA wird zusätzlich gesetzt

sudo nmcli connection up "preconfigured"

# Prüfen (Interface-Name aus nmcli-Ausgabe verwenden, z.B. wlan0 oder eth0)
ip addr show wlan0
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
# SealedSecret erzeugen (ersetze <dein-passwort>)
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=WEBPASSWORD="<dein-passwort>" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/pihole/pihole-sealed-secret.yaml

# Ins Repo committen und deployen
git add apps/pihole/pihole-sealed-secret.yaml
git commit -m "feat(pihole): add sealed secret for admin password"

kubectl apply -f apps/pihole/pihole-sealed-secret.yaml
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
echo "<mqtt-broker-ip> raspberrypi.fritz.box" >> /etc/pihole/custom.list
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
# → Events prüfen ob MetalLB eine IP aus dem Pool zugewiesen hat
# → Ohne MetalLB: klipper-lb (k3s built-in ServiceLB) übernimmt — dann bindet der Service an die Node-IP

# Port 53 bereits belegt auf dem Node?
ssh stefan@k3s.fritz.box "sudo ss -tulpn | grep :53"
# → systemd-resolved hört auf 127.0.0.53, nicht auf dem Netzwerk-Interface → kein Konflikt

# IPv6 DNS antwortet nicht?
ssh stefan@k3s.fritz.box "ip addr | grep fd9d"
# → ULA-Adresse fd9d:c2c4:babc::1/64 muss vorhanden sein (auf wlan0 oder eth0)
```

---

## Weiter: [04c — Seafile deployen](./04c-seafile.md)
