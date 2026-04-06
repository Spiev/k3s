# Pi-hole deployen

Voraussetzung: [03 — MetalLB](../platform/03-metallb.md) eingerichtet, [05 — Sealed Secrets](../platform/05-sealed-secrets.md) eingerichtet, Dual-Stack-Cluster läuft (siehe [02 — k3s installieren](../platform/02-k3s-install.md)).

> [!NOTE]
> MetalLB ist für Pi-hole **keine Voraussetzung mehr**. Klipper/ServiceLB (k3s-Standard) bindet Port 53 direkt auf der Node-IP — das reicht für DNS. MetalLB bringt hier nur dann einen Vorteil, wenn der Node per Ethernet angebunden ist (stabile VIP unabhängig von der Node-IP). Siehe [03 — MetalLB](../platform/03-metallb.md).

Pi-hole läuft als DNS-Resolver für das gesamte Heimnetz. Da es ein Neudeploy ist (keine komplexen Daten zu migrieren), wird das Volume direkt mit `local-path` bereitgestellt.

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

Der k3s-Node bekommt eine feste IPv6-Adresse aus dem ULA-Prefix der Fritz!Box (`<ULA-PREFIX>/64`). ULA-Adressen ändern sich nie — unabhängig vom ISP-Prefix. Eine freie Adresse aus dem ULA-Bereich wählen, z.B. `<ULA-PREFIX>::1`.

```bash
# Auf dem k3s-Node: aktive Verbindung und Interface ermitteln
nmcli connection show --active
# → Name und DEVICE notieren (z.B. "preconfigured" / wlan0, oder "Wired connection 1" / eth0)

# Statische IPv6 zur aktiven Verbindung hinzufügen (Connection-Name anpassen)
sudo nmcli connection modify "preconfigured" \
  ipv6.addresses "<ULA-PREFIX>::1/64" \
  ipv6.method "auto"        # SLAAC bleibt aktiv, ULA wird zusätzlich gesetzt

sudo nmcli connection up "preconfigured"

# Prüfen (Interface-Name aus nmcli-Ausgabe verwenden, z.B. wlan0 oder eth0)
ip addr show wlan0
# → <ULA-PREFIX>::1/64 sollte erscheinen
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
  --from-literal=FTLCONF_webserver_api_password="<dein-passwort>" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/pihole/pihole-sealed-secret.yaml

# Ins Repo committen
git add apps/pihole/pihole-sealed-secret.yaml
git commit -m "feat(pihole): add sealed secret for admin password"
```

> Das SealedSecret wird erst in Schritt 4 deployed — der Namespace muss zuerst existieren.

---

## Schritt 4 — Manifeste deployen

Reihenfolge ist wichtig: erst Namespace, dann Secret, dann den Rest — so startet der Pod direkt ohne Fehler-Zwischenzustand.

```bash
# 1. Namespace anlegen (--save-config verhindert Warning beim späteren kubectl apply)
kubectl create namespace pihole --save-config

# 2. SealedSecret deployen — Controller legt das echte Secret sofort an
kubectl apply -f apps/pihole/pihole-sealed-secret.yaml

# 3. PVC, Deployment und Services deployen
kubectl apply -f apps/pihole/pihole.yaml
```

> `kubectl apply -f apps/pihole/` würde auch die `.example`-Dateien anwenden — daher explizit die Dateien benennen.

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

## Schritt 5 — Konfiguration übertragen (Teleporter)

Pi-hole hat eine eingebaute Import/Export-Funktion die alle Einstellungen auf einmal überträgt: DNS-Einträge, CNAMEs, Blocklisten, Whitelists, Einstellungen.

**Export auf dem alten Pi-hole:**
Admin-UI → **Settings → Teleporter → Backup**

**Import auf dem neuen Pi-hole:**
Admin-UI → **Settings → Teleporter → Restore** → exportierte Datei hochladen

---

## Schritt 6 — Pi-hole testen (vor der Umstellung)

Erst testen bevor die Fritz!Box umgestellt wird:

```bash
dig @<METALLB-IPV4-VIP> google.com
dig @<METALLB-IPV6-VIP> google.com
```

Beide Anfragen sollten eine Antwort liefern. Wenn ja: Pi-hole funktioniert korrekt.

---

## Schritt 7 — Fritz!Box umstellen

In der **Fritz!Box** unter Heimnetz → Netzwerk → DNS:

- DNS-Server (IPv4): `<METALLB-IPV4-VIP>`
- DNS-Server (IPv6): `<METALLB-IPV6-VIP>`

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
ssh stefan@k3s.fritz.box "ip addr | grep <ULA-PREFIX>"
# → ULA-Adresse <ULA-PREFIX>::1/64 muss vorhanden sein (auf wlan0 oder eth0)
```

---

## Weiter: [Seafile deployen](./seafile.md)
