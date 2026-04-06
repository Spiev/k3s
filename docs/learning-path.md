# Kubernetes Learning Path — Raspberry Pi 5

Ziel: Schrittweiser Einstieg in Kubernetes mit k3s auf zwei Raspberry Pi 5 (je 8 GB RAM). Server-Node: 256 GB NVMe, Agent-Node (nach Migration): 2 TB NVMe. Vollständige Migration aller Docker-Services angestrebt.

→ [Architektur-Übersicht](./architecture.md) — Gesamtbild, Netzwerkfluss, Komponenten

---

## Architekturentscheidungen (Vorab)

### Warum k3s?
- Leichtgewichtig, ARM64-ready, enthält bereits Traefik (Ingress), CoreDNS, Flannel (CNI) und local-path-provisioner
- Produktionsreif, aber deutlich einfacher als "full" Kubernetes
- Einfache Multi-Node-Erweiterung: Agent einfach joinen lassen

### Warum local-path als Storage?

`local-path-provisioner` ist k3s built-in und die richtige Wahl für dieses Setup:
- Daten liegen direkt auf dem Node-Filesystem — wie Docker-Volumes, direkt les- und sicherbar
- Services sind sowieso fest einem Node zugeordnet (Hardware/Speicherplatz) → kein Vorteil durch Replikation
- Backup via Restic direkt aus dem Filesystem, kein Snapshot-Overhead

→ Vollständige Begründung: [`docs/decisions/storage.md`](decisions/storage.md)

### Warum Flux CD als GitOps?
- Leichter als ArgoCD (passt besser auf einen Raspi)
- Pull-based: kein Webhook nötig, funktioniert auch hinter NAT
- Kompatibel mit Sealed Secrets → Secrets können ins Git-Repo

---

## Phase 0 — Hardware & OS (Tag 1–2)

### Raspberry Pi 5 einrichten

**OS: Raspberry Pi OS Lite (64-bit, Bookworm)**
Bringt alle Hardware-Tools nativ mit (`raspi-config`, `vcgencmd`, `rpi-eeprom-update`) — wichtig für Headless-Betrieb und künftige Hardware-Anpassungen. k3s läuft auf Raspberry Pi OS problemlos.

1. Raspberry Pi OS Lite (64-bit) mit dem Raspberry Pi Imager direkt auf die NVMe flashen
2. Erster Boot: EEPROM aktualisieren (`sudo rpi-eeprom-update -a`)
3. cgroups in `/boot/firmware/cmdline.txt` aktivieren, Swap deaktivieren

Details: [docs/01-os-setup.md](./platform/01-os-setup.md)

**Warum NVMe wichtig ist:**
Kubernetes schreibt ständig auf Disk (Etcd, Logs, Volumes). SD-Karten sterben dabei nach Wochen. NVMe ist hier keine Kür.

---

## Phase 1 — k3s & Grundkonzepte (Woche 1)

### k3s installieren

```bash
curl -sfL https://get.k3s.io | sh -
# Kubeconfig für deinen User kopieren
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### Was k3s out-of-the-box mitbringt
- **Traefik** — Ingress Controller (HTTP/HTTPS-Routing in den Cluster)
- **CoreDNS** — Cluster-internes DNS (`service.namespace.svc.cluster.local`)
- **Flannel** — Netzwerk zwischen Pods
- **local-path-provisioner** — Storage direkt auf dem Node-Filesystem (produktiv genutzt)
- **Etcd** — Cluster-State-Datenbank (läuft embedded)

### Grundkonzepte lernen

Die wichtigsten Kubernetes-Objekte, in Reihenfolge des Verständnisses:

```
Pod → kleinste Einheit, ein oder mehrere Container
Deployment → verwaltet Pods (gewünschte Anzahl, Rolling Updates)
Service → stabiler Netzwerk-Endpunkt für Pods (ClusterIP / NodePort / LoadBalancer)
ConfigMap → Konfiguration als Key-Value (kein Secret)
Secret → wie ConfigMap, aber base64-kodiert (und mit Sealed Secrets verschlüsselbar)
PersistentVolume (PV) → tatsächlicher Speicher
PersistentVolumeClaim (PVC) → Pods "beantragen" Speicher über PVCs
Namespace → logische Trennung von Ressourcen
Ingress / IngressRoute → externes HTTP(S)-Routing in Services
```

**Erste Schritte mit kubectl:**
```bash
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get services --all-namespaces

# Ein Objekt im Detail ansehen
kubectl describe pod <name> -n <namespace>
# Logs eines Pods
kubectl logs <pod-name> -n <namespace>
# In einen Pod "einsteigen"
kubectl exec -it <pod-name> -n <namespace> -- sh
```

**Empfohlene Lernressource:** [Kubernetes Docs — Concepts](https://kubernetes.io/docs/concepts/)
Besonders relevant: Workloads, Services & Networking, Storage.

---

## Phase 2 — Networking & Ingress (Woche 1–2)

k3s bringt Traefik mit. Das ist dein Nginx-Ersatz im Cluster.

### Service-Typen verstehen
```
ClusterIP    → nur innerhalb des Clusters erreichbar (default)
NodePort     → Port auf dem Node öffnen (für Tests, nicht für Produktion)
LoadBalancer → externe IP zuweisen (braucht MetalLB auf bare metal)
```

### MetalLB installieren

k3s bringt ein eingebautes ServiceLB (Klipper) mit, das `LoadBalancer`-Services einfach auf die Node-IP bindet. Für eine stabile VIP die bei Multi-Node zwischen Nodes wandern kann, braucht es MetalLB.

**Schritt 1 — k3s ServiceLB deaktivieren** (in `/etc/rancher/k3s/config.yaml`):
```yaml
disable:
  - servicelb
```
`sudo systemctl restart k3s`

**Schritt 2 — MetalLB deployen:**
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

**Schritt 3 — IP-Pool konfigurieren** (`infrastructure/metallb/metallb.yaml`):
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.178.200-192.168.178.220   # freier Bereich im Heimnetz
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

Ab jetzt bekommt jeder `type: LoadBalancer`-Service eine dedizierte IP aus dem Pool — kein Port-Sharing, kein Konflikt zwischen Services.

> **Warum MetalLB statt kube-vip?** MetalLB ist purpose-built für genau diese Aufgabe und in professionellen On-Premises-Kubernetes-Umgebungen deutlich verbreiteter. kube-vip löst primär Control Plane HA (3+ Nodes) — in diesem Setup nicht relevant.

### Traefik konfigurieren

Traefik in k3s läuft als `IngressController`. Es gibt zwei Wege, Routing zu definieren:
- **Ingress** (Kubernetes-Standard, einfacher)
- **IngressRoute** (Traefik-spezifisch, mächtiger — Empfehlung)

### cert-manager / TLS

**Noch nicht nötig.** Während der Migration terminiert nginx (auf dem alten Raspi) TLS — Traefik bekommt nur HTTP-Anfragen intern und braucht keine eigenen Zertifikate.

cert-manager kommt erst ins Spiel wenn entschieden wird, ob Traefik nginx als externen Einstiegspunkt ablöst. Das ist eine spätere Entscheidung (siehe Phase 8).

---

## Phase 3 — Storage: local-path (Woche 2)

k3s bringt den `local-path-provisioner` bereits mit — keine Installation nötig.

### Konzepte

```yaml
# PersistentVolumeClaim — so beantragen Pods ihren Speicher
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

Daten landen unter `/var/lib/rancher/k3s/storage/<pvc-name>/` auf dem Node — direkt lesbar, direkt sicherbar mit Restic.

### Backup

```
/var/lib/rancher/k3s/storage/<pvc-name>/
       │  direkt lesbar
       ▼
  Restic → Hetzner S3
```

Details: [docs/operations/backup-restore.md](./operations/backup-restore.md)

### Weg zum zweiten Node

Wenn irgendwann alle Services auf k3s laufen und der alte Raspi aus dem Docker-Betrieb geht:
1. Docker stoppen, Daten sichern
2. k3s Agent installieren und dem Cluster joinen
3. Services explizit via `nodeSelector` auf die gewünschten Nodes pinnen

---

## Phase 4 — Erste Migration: FreshRSS (Woche 3)

FreshRSS ist ideal als erster Kandidat:
- Ein einziges Volume (`./config`) — kein Datenbankcluster
- Kein komplexes Netzwerk-Setup
- Leicht rückgängig zu machen (Docker-Container läuft parallel weiter bis zum Cutover)

### Migrations-Strategie

```
1. FreshRSS in k3s deployen (leeres Volume)
2. Daten aus Docker-Volume in local-path-PVC kopieren
3. Testen (parallel zum alten Container)
4. DNS/Traefik auf k3s umschalten
5. Docker-Container stoppen
```

### Daten-Migration (Docker → local-path PVC)

```bash
# Temporärer Pod, der das PVC mountet
kubectl run migration --image=alpine --restart=Never \
  -n freshrss --overrides='
{
  "spec": {
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "freshrss-config"}}],
    "containers": [{
      "name": "migration",
      "image": "alpine",
      "command": ["sleep", "3600"],
      "volumeMounts": [{"name": "data", "mountPath": "/data"}]
    }]
  }
}'

# Daten vom alten Server hineinkopieren
kubectl cp /pfad/zu/docker/freshrss/config/. freshrss/migration:/data/
```

Die fertigen Manifeste für FreshRSS werden in `apps/freshrss/` im Repo liegen.

---

## Phase 4b — Zweite Migration: Seafile (Woche 3–4)

Seafile ist der ideale nächste Schritt nach FreshRSS, weil es alle neuen Konzepte einführt, die danach für Flux/GitOps gebraucht werden: mehrere zusammengehörige Pods, Service-to-Service-Kommunikation und Secrets.

### Architektur in k3s

Das offizielle `seafileltd/seafile-mc`-Image enthält Seafile, Seahub **und** memcached — also nur 2 Pods:

```
[Ingress/Traefik]
      ↓
[seafile-mc Pod]  ←→  ClusterIP Service  ←→  [MariaDB Pod]
      ↓
[seafile-data PVC]  +  [mariadb-data PVC]
```

### Neue Konzepte gegenüber FreshRSS

- **Mehrere Deployments in einem Namespace** — Seafile und MariaDB als getrennte Deployments
- **Service-to-Service-Kommunikation** — Seafile spricht MariaDB über `mariadb.seafile.svc.cluster.local` an (CoreDNS)
- **Sealed Secrets in der Praxis** — DB-Passwort, Seafile `SECRET_KEY`, Admin-Credentials
- **Startup-Reihenfolge** — MariaDB muss vor Seafile bereit sein (`initContainers` oder `startupProbe`)

### Warum Seafile trotz Sync-Vorteil sorgfältig migriert werden sollte

Seafile ist sync-basiert: die Datei-Blobs existieren auf allen Clients lokal. Ein Cluster-Ausfall bedeutet also keinen Datenverlust. **Was verloren gehen würde:** Versionshistorie, Share-Links, Bibliotheks-Metadaten (alles in MariaDB). Backups der MariaDB sind deshalb trotzdem wichtig.

### Migrationsstrategie

```
1. Seafile in k3s deployen (leere DB + leeres Volume)
2. MariaDB-Dump vom alten Server einspielen
3. Seafile-Datenbibliothek ins neue PVC kopieren (rsync oder kubectl cp)
4. Seafile-Client auf einem Gerät auf neue URL umstellen → Test-Sync
5. DNS umschalten, alle Clients auf neue URL
6. Docker-Container stoppen
```

---

## Phase 5 — GitOps mit Flux CD (Woche 4–5)

### Repository-Struktur (Ziel)

```
k3s/
├── clusters/
│   └── raspi/              ← Cluster-spezifische Flux-Konfiguration
│       ├── flux-system/    ← Flux selbst (auto-generiert)
│       └── apps.yaml       ← zeigt auf apps/
├── apps/
│   ├── freshrss/           ← FreshRSS Manifeste
│   └── cert-manager/
├── infrastructure/
│   └── traefik/            ← Traefik-Konfiguration
└── docs/
```

### Traefik aus k3s herauslösen

Traefik ist in k3s eingebaut und an die k3s-Version gekoppelt — Versionsverwaltung und Renovate-Tracking sind so nicht möglich. Mit Flux lässt sich das sauber lösen:

**Schritt 1 — Eingebautes Traefik deaktivieren** (in `/etc/rancher/k3s/config.yaml` auf dem Pi):

```yaml
disable:
  - traefik
  - local-storage
```

`sudo systemctl restart k3s` — Traefik wird aus dem Cluster entfernt.

**Schritt 2 — Traefik als Flux HelmRelease ins Repo** (`infrastructure/traefik/helmrelease.yaml`):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: kube-system
spec:
  url: https://traefik.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: kube-system
spec:
  chart:
    spec:
      chart: traefik
      version: "34.4.0"   # Renovate tracked das automatisch
      sourceRef:
        kind: HelmRepository
        name: traefik
```

Flux deployed das beim nächsten Sync automatisch. Renovate erkennt `HelmRelease`-Ressourcen nativ und schlägt Updates als PRs vor.

> **Wichtig:** Erst Traefik in k3s deaktivieren, dann Flux deployen — sonst gibt es CRD-Ownership-Konflikte (beide versuchen dieselben Gateway-CRDs zu verwalten).

> **HelmChart vs. HelmRelease:** k3s hat einen eigenen `HelmChart`-Typ (`helm.cattle.io/v1`) der ebenfalls von Renovate unterstützt wird. Flux nutzt `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) mit separatem `HelmRepository`-Objekt. Beide funktionieren, aber sobald Flux da ist, ist `HelmRelease` der konsistentere Weg.

### Flux installieren & bootstrappen

```bash
curl -s https://fluxcd.io/install.sh | sudo bash

flux bootstrap github \
  --owner=<dein-github-user> \
  --repository=k3s \
  --branch=main \
  --path=clusters/raspi \
  --personal
```

Flux richtet sich selbst ein und überwacht ab sofort dieses Repository. Jeder Commit zu `main` → Flux deployed automatisch.

---

## Phase 6 — Secrets Management (Woche 4)

Secrets in Kubernetes sind nur base64-kodiert, nicht verschlüsselt. Für ein öffentliches GitHub-Repo brauchen wir Sealed Secrets.

### Sealed Secrets

```bash
# Controller im Cluster installieren (Version prüfen: https://github.com/bitnami-labs/sealed-secrets/releases)
SEALED_SECRETS_VERSION="v0.27.1"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml

# CLI-Tool auf dem Laptop (Arch Linux, x86_64)
KUBESEAL_VERSION="${SEALED_SECRETS_VERSION#v}"
curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar xz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

```bash
# Secret verschlüsseln → kann sicher ins Git-Repo
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=WEBPASSWORD="geheim" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/pihole/pihole-sealed-secret.yaml
```

Das resultierende `SealedSecret` kann gefahrlos in das öffentliche Repo committed werden. Nur der Cluster kann es entschlüsseln.

> **Wichtig:** Den Controller-Schlüssel sofort nach der Installation sichern — Details und vollständige Recovery-Prozedur: [docs/platform/05-sealed-secrets.md](./platform/05-sealed-secrets.md)

---

## Phase 7 — Monitoring (Woche 5)

**kube-prometheus-stack** installiert Prometheus, Grafana und Alertmanager in einem Helm-Chart — inklusive vorgefertigter Dashboards für Node-Metriken, Pod-Ressourcen, PVCs und Kubernetes-Objekte.

Raspberry Pi Hardware-Metriken (CPU-Temperatur etc.) liefert `node_exporter`, der bereits im Stack enthalten ist.

Optional: Prometheus-Integration mit Home Assistant für Automationen auf Basis von Cluster-Metriken.

Details: [docs/operations/monitoring.md](./operations/monitoring.md)

---

## Phase 8 — Multi-Node: Alter Raspi hinzufügen (Zukunft)

**Voraussetzung:** Der alte Raspi (Raspi 5, 8 GB RAM, 2 TB NVMe) läuft erst dann als k3s Agent-Node, wenn alle seine Docker-Services vollständig nach k3s migriert sind. Beide Rollen gleichzeitig sind nicht möglich.

Home Assistant läuft dann auf dem Agent-Node mit `hostNetwork: true` und `nodeAffinity` für den Zigbee-Dongle — kein Umstecken nötig.

Ablauf wenn es soweit ist:
1. **MetalLB einrichten** (falls noch nicht geschehen) — VIP-Pool konfigurieren damit Services eine stabile IP bekommen die zwischen Nodes wandern kann (siehe Phase 2)
2. Docker-Services stoppen, Daten sichern
3. k3s Agent auf dem alten Raspi installieren:

```bash
# Token vom Server-Node holen
sudo cat /var/lib/rancher/k3s/server/node-token

# Auf dem alten Raspi:
curl -sfL https://get.k3s.io | K3S_URL=https://<raspi5-ip>:6443 \
  K3S_TOKEN=<token> sh -
```

3. Services via `nodeSelector` auf die gewünschten Nodes pinnen.

**Node-Rollen:**
- **Server-Node** (Raspi 5): Control-Plane, API-Server, Scheduler, Etcd
- **Agent-Node** (alter Raspi): nur Workloads, kein Control-Plane

---

## Nicht-Ziele (bewusst ausgelassen)

- **High-Availability Control Plane**: Sinnvoll erst ab 3 Nodes. Für 2 Nodes reicht Single-Server-Setup.
- **Kubernetes-Dashboard**: Grafana deckt den Bedarf besser ab.
- **Multi-Cluster-Setups**: Nicht für diesen Use Case.

---

## Reihenfolge der Dokumente

1. `docs/platform/01-os-setup.md` — NVMe-Boot, Raspberry Pi OS, cgroups
2. `docs/platform/02-k3s-install.md` — k3s mit Dual-Stack (IPv4+IPv6), kubectl (lokal + remote), erste Schritte
3. `docs/platform/03-metallb.md` — MetalLB einrichten (LoadBalancer-VIPs für Bare Metal)
4. `docs/services/freshrss.md` — FreshRSS migrieren
5. `docs/platform/05-sealed-secrets.md` — Sealed Secrets einrichten (Voraussetzung für alle weiteren Secrets)
6. `docs/services/pihole.md` — Pi-hole: DNS via LoadBalancer
7. `docs/services/seafile.md` — Seafile migrieren (Multi-Container, Secrets)
8. `docs/services/immich.md` — Immich migrieren (Restic-Restore-Strategie, großes Volume)
9. `docs/operations/monitoring.md` — Prometheus + Grafana
10. `docs/operations/backup-restore.md` — Backup & Restore, kritische Secrets
