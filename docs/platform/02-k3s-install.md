# 02 — k3s installieren (Dual-Stack: IPv4 + IPv6)

Voraussetzung: [01 — OS Setup](./01-os-setup.md) abgeschlossen. Pi läuft Raspberry Pi OS Bookworm (64-bit) von NVMe, cgroups aktiv, kein Swap.

---

## Warum Dual-Stack?

Dual-Stack (IPv4 + IPv6 gleichzeitig) ist eine **Install-Time-Entscheidung** — nachträgliches Aktivieren ist nicht möglich ohne einen Cluster-Neuinstall. Daher wird es von Anfang an konfiguriert.

Dual-Stack ist zwingend erforderlich für:

- **Pi-hole** — soll IPv6-DNS-Queries aus dem LAN entgegennehmen; ohne Dual-Stack bekommt ein LoadBalancer-Service keine IPv6-External-IP
- **Matter-Hub** (Home Assistant) — Matter setzt IPv6 voraus
- **Alle modernen Betriebssysteme** — bevorzugen IPv6 wenn verfügbar; DNS-Anfragen kommen regelmäßig über IPv6 an

---

## 1. Konfiguration anlegen

Vor der Installation die k3s-Konfiguration anlegen — k3s liest sie automatisch beim Start:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
tls-san:
  - k3s.fritz.box
disable:
  - local-storage
cluster-cidr: "10.42.0.0/16,fd42::/56"
service-cidr: "10.43.0.0/16,fd43::/112"
EOF
```

| Parameter | Wert | Bedeutung |
|---|---|---|
| `tls-san` | `k3s.fritz.box` | Hostname im TLS-Zertifikat — ermöglicht Remote-kubectl |
| `disable: local-storage` | — | Verhindert zwei gleichzeitige Default-StorageClasses (Longhorn übernimmt) |
| `cluster-cidr` | `10.42.0.0/16,fd42::/56` | Pod-Netz (IPv4 + IPv6) |
| `service-cidr` | `10.43.0.0/16,fd43::/112` | Service-ClusterIPs (IPv4 + IPv6) |

Die IPv6-Ranges sind ULA (Unique Local Addresses, `fd00::/8`) — privat, nicht geroutet ins Internet.

---

## 2. k3s installieren

```bash
curl -sfL https://get.k3s.io | sh -
```

Das Script:
- lädt k3s herunter (single binary, enthält alles)
- richtet einen systemd-Service ein
- startet den Cluster mit der `config.yaml` aus Schritt 1

Status prüfen:
```bash
sudo systemctl status k3s
```

---

## 3. kubectl einrichten

### Auf dem Pi

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

k3s schreibt die Kubeconfig standardmäßig nach `/etc/rancher/k3s/k3s.yaml` (nur root-lesbar). `KUBECONFIG` explizit setzen — für fish:

```bash
echo 'set -gx KUBECONFIG ~/.kube/config' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Für bash:
```bash
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

Ab jetzt funktioniert `kubectl` direkt ohne sudo.

### Vom Laptop

kubectl installieren (Arch Linux):

```bash
sudo pacman -S kubectl
```

Kubeconfig vom Pi kopieren und Server-Adresse `127.0.0.1` auf den Hostnamen anpassen:

```bash
# Auf dem Laptop ausführen:
mkdir -p ~/.kube
scp <user>@k3s.fritz.box:~/.kube/config ~/.kube/config-raspi
sed -i 's/127.0.0.1/k3s.fritz.box/g' ~/.kube/config-raspi
```

`KUBECONFIG` setzen — für fish:
```bash
echo 'set -gx KUBECONFIG ~/.kube/config-raspi' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Verbindung testen:
```bash
kubectl get nodes
# NAME   STATUS   ROLES           AGE   VERSION
# k3s    Ready    control-plane   ...   v1.x.x+k3s1
```

> **Hinweis:** `~/.kube/config-raspi` enthält Client-Zertifikat und privaten Schlüssel — wer diese Datei hat, hat vollen Cluster-Zugriff. Nicht committen, nicht teilen.

> **Nach einem Cluster-Neuinstall** generiert k3s neue TLS-Zertifikate. Die Kubeconfig muss dann erneut vom Pi kopiert werden (gleiche Schritte wie oben).

---

## 4. Was k3s mitbringt

Nach der Installation laufen bereits mehrere System-Pods:

```bash
kubectl get pods --all-namespaces
```

| Namespace | Pod | Funktion |
|---|---|---|
| `kube-system` | `traefik-*` | Ingress Controller (HTTP/HTTPS-Routing) |
| `kube-system` | `coredns-*` | Cluster-internes DNS |
| `kube-system` | `metrics-server-*` | Ressourcen-Metriken für `kubectl top` |
| `kube-system` | `svclb-traefik-*` | Service LoadBalancer (k3s built-in) |

Flannel (CNI) läuft als Kernel-Modul, nicht als Pod. `local-path-provisioner` ist deaktiviert (siehe Konfiguration oben).

---

## 5. Grundkonzepte — die wichtigsten Objekte

```
Pod
  └── kleinste deploybare Einheit; ein oder mehrere Container
  └── kurzlebig, wird bei Problemen neu gestartet

Deployment
  └── verwaltet eine gewünschte Anzahl identischer Pods
  └── übernimmt Rolling Updates und Rollbacks

Service
  └── stabiler Netzwerk-Endpunkt für eine Gruppe von Pods
  └── Pods kommen und gehen, die Service-IP bleibt gleich
  └── Typen: ClusterIP (intern), NodePort (Node-Port öffnen), LoadBalancer (externe IP)

Namespace
  └── logische Trennung von Ressourcen (z.B. ein Namespace pro Service)

ConfigMap
  └── Konfiguration als Key-Value, im Klartext

Secret
  └── wie ConfigMap, aber base64-kodiert (≠ verschlüsselt!)
  └── für Passwörter, API-Keys etc. → später: Sealed Secrets

PersistentVolume (PV)
  └── tatsächlicher Speicher (von Longhorn oder anderem Provisioner bereitgestellt)

PersistentVolumeClaim (PVC)
  └── Pods "beantragen" Speicher über PVCs
  └── PVC bindet sich an ein passendes PV

Ingress / IngressRoute
  └── externes HTTP(S)-Routing → welche Domain geht zu welchem Service
```

---

## 6. Erste Schritte mit kubectl

### Grundlegende Befehle

```bash
# Überblick über den Cluster
kubectl get nodes
kubectl get pods --all-namespaces

# Kurzform: -A statt --all-namespaces
kubectl get pods -A

# Ein Objekt im Detail
kubectl describe pod <name> -n <namespace>

# Logs anschauen
kubectl logs <pod-name> -n <namespace>
kubectl logs -f <pod-name> -n <namespace>   # live (follow)

# In einen laufenden Pod einsteigen
kubectl exec -it <pod-name> -n <namespace> -- sh

# Ressourcenverbrauch
kubectl top nodes
kubectl top pods -A
```

### Etwas deployen — erstes Experiment

Einen Nginx-Pod starten, ohne YAML zu schreiben:

```bash
# Namespace anlegen
kubectl create namespace test

# Deployment erstellen
kubectl create deployment nginx --image=nginx:alpine -n test

# Warten bis der Pod läuft
kubectl get pods -n test -w   # -w = watch (Ctrl+C zum Beenden)

# Pod von innen ansehen
kubectl exec -it deploy/nginx -n test -- sh
# wget -qO- http://localhost   → gibt Nginx-Startseite aus
exit

# Aufräumen
kubectl delete namespace test
```

### YAML verstehen — was kubectl wirklich macht

Jede `kubectl create`-Aktion erzeugt Kubernetes-Objekte. Diese lassen sich auch als YAML anschauen:

```bash
kubectl get deployment nginx -n test -o yaml
```

Das ist der Weg hin zu "alles als YAML im Git-Repo" — was später mit Flux passiert.

---

## 7. Traefik — der eingebaute Ingress Controller

Traefik läuft bereits. Prüfen:

```bash
kubectl get svc -n kube-system traefik
# EXTERNAL-IP zeigt die Node-IP — mit Dual-Stack beide (IPv4 + IPv6)
```

Traefik hört auf Port 80 und 443 des Raspberry Pi. Alles weitere wird über Ingress-Objekte konfiguriert — das kommt mit dem ersten Service (FreshRSS).

**Traefik Dashboard** (nur lokal):
```bash
kubectl port-forward -n kube-system svc/traefik 9000:9000
# Browser: http://localhost:9000/dashboard/
```

---

## 8. k3s-spezifische Details

**Konfigurationsdatei:** `/etc/rancher/k3s/config.yaml`
```bash
# Änderungen erfordern:
sudo systemctl restart k3s
```

**Kubeconfig-Pfad:** `/etc/rancher/k3s/k3s.yaml`

**Daten-Verzeichnis:** `/var/lib/rancher/k3s/`
- `server/db/` — etcd-Daten (Cluster-State)
- `agent/` — lokale Pod-Daten, Images

**Logs:**
```bash
sudo journalctl -u k3s -f
```

**Neustart:**
```bash
sudo systemctl restart k3s
```

**Deinstallation** (löscht alles inkl. etcd):
```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## 9. k3s aktualisieren

k3s wird durch erneutes Ausführen des Install-Scripts aktualisiert — es erkennt die vorhandene Installation und führt ein In-Place-Update durch. Der Cluster läuft danach weiter.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
```

Oder auf eine konkrete Version pinnen:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.2+k3s1 sh -
```

Aktuelle Version prüfen:

```bash
k3s --version
```

> **Traefik-Version:** Traefik ist aktuell an die k3s-Version gekoppelt — ein k3s-Update bringt automatisch die zugehörige Traefik-Version mit. Die langfristige Lösung ist, Traefik unabhängig von k3s zu verwalten (→ Phase 5, Flux CD).

---

## 10. Abschluss-Check

```bash
# Node Ready
kubectl get nodes
# STATUS = Ready

# Alle System-Pods laufen
kubectl get pods -A
# Alle RUNNING oder COMPLETED, nichts in CrashLoopBackOff

# Dual-Stack: Traefik hat IPv4 und IPv6 External-IP
kubectl get svc -n kube-system traefik
# EXTERNAL-IP: <IPv4>,<IPv6>

# Ressourcenverbrauch nach der Installation
kubectl top nodes
# k3s braucht im Leerlauf ca. 500 MB RAM
```

---

---

## Weiter: [04 — Longhorn Storage](./04-longhorn.md)
