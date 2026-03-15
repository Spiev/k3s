# 02 — k3s installieren & erste Schritte

Voraussetzung: [01 — OS Setup](./01-os-setup.md) abgeschlossen. Pi läuft Raspberry Pi OS Bookworm (64-bit) von NVMe, cgroups aktiv, kein Swap.

---

## 1. k3s installieren

```bash
curl -sfL https://get.k3s.io | sh -
```

Das Script:
- lädt k3s herunter (single binary, enthält alles)
- richtet einen systemd-Service ein
- startet den Cluster

Status prüfen:
```bash
sudo systemctl status k3s
sudo k3s kubectl get nodes
# NAME    STATUS   ROLES                  AGE   VERSION
# raspi   Ready    control-plane,master   1m    v1.x.x+k3s1
```

### kubectl für deinen User einrichten

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

Das k3s-kubectl schaut standardmäßig zuerst nach `/etc/rancher/k3s/k3s.yaml` (nur root-lesbar) statt `~/.kube/config`. Daher `KUBECONFIG` explizit setzen — für fish:

```bash
echo 'set -gx KUBECONFIG ~/.kube/config' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Für bash/zsh (falls auf einem anderen System):
```bash
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

Ab jetzt funktioniert `kubectl` direkt ohne sudo und ohne Prefix.

### kubectl vom Laptop aus einrichten

kubectl auf dem Laptop installieren:

```bash
# Arch Linux
sudo pacman -S kubectl
```

#### TLS-SAN für den Hostnamen konfigurieren

k3s stellt sein API-Zertifikat standardmäßig nur für `localhost`, `kubernetes` und den Kurznamen des Hosts aus. Damit eine Verbindung über den vollständigen Hostnamen (z.B. `k3s.fritz.box`) funktioniert, muss dieser als SAN (Subject Alternative Name) eingetragen werden.

Auf dem Raspi:

```bash
# 1. k3s-Konfiguration mit dem Hostnamen anlegen
printf 'tls-san:\n  - <raspi-hostname>\n' | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
```

> Beispiel: `printf 'tls-san:\n  - k3s.fritz.box\n' | sudo tee /etc/rancher/k3s/config.yaml > /dev/null`

```bash
# 2. k3s stoppen, Serving-Zertifikat löschen (wird beim Start neu generiert)
sudo systemctl stop k3s
sudo rm /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
sudo rm /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key

# 3. k3s starten — generiert neues Zertifikat mit dem SAN
sudo systemctl start k3s
```

Prüfen ob der Hostname im neuen Zertifikat enthalten ist:
```bash
sudo openssl x509 -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt -noout -ext subjectAltName
# DNS:k3s.fritz.box sollte in der Ausgabe erscheinen
```

#### Kubeconfig auf den Laptop kopieren

```bash
# Auf dem Laptop ausführen
mkdir -p ~/.kube
scp <user>@<raspi-hostname>:~/.kube/config ~/.kube/config-raspi
```

> Beispiel: `scp stefan@k3s.fritz.box:~/.kube/config ~/.kube/config-raspi`

Die Datei enthält als Server-Adresse `127.0.0.1` — das muss auf den Hostnamen des Raspberry Pi geändert werden:

```bash
sed -i 's/127.0.0.1/<raspi-hostname>/g' ~/.kube/config-raspi
```

> Beispiel: `sed -i 's/127.0.0.1/k3s.fritz.box/g' ~/.kube/config-raspi`

`KUBECONFIG` in der Shell setzen — für fish:

```bash
echo 'set -gx KUBECONFIG ~/.kube/config-raspi' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Für bash/zsh:
```bash
echo 'export KUBECONFIG=~/.kube/config-raspi' >> ~/.bashrc
source ~/.bashrc
```

Verbindung testen:

```bash
kubectl get nodes
# NAME    STATUS   ROLES                  AGE   VERSION
# k3s     Ready    control-plane,master   ...   v1.x.x+k3s1
```

Ab jetzt können alle `kubectl`-Befehle und `kubectl apply -f` direkt vom Laptop ausgeführt werden — ohne SSH.

> **Hinweis:** Die `~/.kube/config-raspi` enthält Client-Zertifikat und privaten Schlüssel — wer diese Datei hat, hat vollen Cluster-Zugriff. Nicht committen, nicht teilen.

---

## 2. Was k3s mitbringt

Nach der Installation laufen bereits mehrere System-Pods:

```bash
kubectl get pods --all-namespaces
```

| Namespace | Pod | Funktion |
|---|---|---|
| `kube-system` | `traefik-*` | Ingress Controller (HTTP/HTTPS-Routing) |
| `kube-system` | `coredns-*` | Cluster-internes DNS |
| `kube-system` | `local-path-provisioner-*` | Einfacher Storage (für erste Tests) |
| `kube-system` | `metrics-server-*` | Ressourcen-Metriken für `kubectl top` |
| `kube-system` | `svclb-traefik-*` | Service LoadBalancer (k3s built-in) |

Flannel (CNI) läuft als Kernel-Modul, nicht als Pod.

---

## 3. Grundkonzepte — die wichtigsten Objekte

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

## 4. Erste Schritte mit kubectl

### Grundlegende Befehle

```bash
# Überblick über den Cluster
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get services --all-namespaces

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

## 5. Traefik — der eingebaute Ingress Controller

Traefik läuft bereits. Prüfen:

```bash
kubectl get svc -n kube-system traefik
# EXTERNAL-IP zeigt die Node-IP (k3s nutzt den built-in LoadBalancer)
```

Traefik hört auf Port 80 und 443 des Raspberry Pi. Alles weitere wird über Ingress-Objekte konfiguriert — das kommt mit dem ersten Service (FreshRSS).

**Traefik Dashboard** (nur lokal):
```bash
kubectl port-forward -n kube-system svc/traefik 9000:9000
# Browser: http://localhost:9000/dashboard/
```

---

## 6. k3s-spezifische Details

**Konfigurationsdatei:**
```bash
# k3s-Verhalten beim Start anpassen
sudo vim /etc/rancher/k3s/config.yaml
# Änderungen erfordern: sudo systemctl restart k3s
```

**Kubeconfig-Pfad:** `/etc/rancher/k3s/k3s.yaml`

**Daten-Verzeichnis:** `/var/lib/rancher/k3s/`
- `server/db/` — Etcd-Daten (Cluster-State)
- `agent/` — lokale Pod-Daten, Images

**Logs:**
```bash
sudo journalctl -u k3s -f
```

**Neustart / Update:**
```bash
# k3s neustarten
sudo systemctl restart k3s

# k3s updaten (selbes Script wie Installation)
curl -sfL https://get.k3s.io | sh -
```

**Deinstallation** (falls nötig):
```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## 7. Abschluss-Check

```bash
# Node ist Ready
kubectl get nodes
# STATUS = Ready

# Alle System-Pods laufen
kubectl get pods -A
# Alle RUNNING oder COMPLETED, nichts in CrashLoopBackOff

# Traefik hat eine externe IP
kubectl get svc -n kube-system traefik
# EXTERNAL-IP = IP des Raspberry Pi

# Ressourcenverbrauch nach der Installation
kubectl top nodes
# k3s braucht im Leerlauf ca. 500 MB RAM
```

---

## Weiter: [03 — Longhorn Storage](./03-longhorn.md)
