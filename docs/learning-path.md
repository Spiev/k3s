# Kubernetes Learning Path — Raspberry Pi 5

Ziel: Schrittweiser Einstieg in Kubernetes mit k3s auf einem Raspberry Pi 5 (8 GB RAM, 256 GB NVMe), ausgehend vom bestehenden Docker-Setup. Erster Migrationskanditat: FreshRSS.

---

## Architekturentscheidungen (Vorab)

### Warum k3s?
- Leichtgewichtig, ARM64-ready, enthält bereits Traefik (Ingress), CoreDNS, Flannel (CNI) und local-path-provisioner
- Produktionsreif, aber deutlich einfacher als "full" Kubernetes
- Einfache Multi-Node-Erweiterung: Agent einfach joinen lassen

### Warum Longhorn als Storage von Anfang an?
Deine Services sind "bedingt stateless" — sie brauchen persistente Volumes. Die Frage ist: welche Storage-Lösung wächst mit?

| Option | Replikation | ARM64 | Komplexität | Empfehlung |
|---|---|---|---|---|
| `local-path-provisioner` (k3s built-in) | ❌ | ✅ | minimal | Nur für Tests |
| NFS | ❌ (SPOF) | ✅ | niedrig | Nein |
| Rook/Ceph | ✅ | ✅ | sehr hoch | Overkill für 2 Nodes |
| **Longhorn** | **✅** | **✅** | **mittel** | **✅ Empfehlung** |

Longhorn ist das Storage-System, das von Rancher (k3s-Macher) für genau diesen Use Case entwickelt wurde:
- Hyperconverged: Daten liegen auf den Nodes selbst (NVMe)
- Zweiten Node joinen → Longhorn repliziert automatisch
- Web-UI für Volume-Management
- Snapshots, Backups nach S3 möglich

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

Details: [docs/01-os-setup.md](./01-os-setup.md)

**Warum NVMe wichtig ist:**
Kubernetes schreibt ständig auf Disk (Etcd, Longhorn, Logs). SD-Karten sterben dabei nach Wochen. NVMe ist hier keine Kür.

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
- **local-path-provisioner** — einfacher Storage (nur für erste Tests, kein Longhorn-Ersatz)
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

### Traefik konfigurieren

Traefik in k3s läuft als `IngressController`. Es gibt zwei Wege, Routing zu definieren:
- **Ingress** (Kubernetes-Standard, einfacher)
- **IngressRoute** (Traefik-spezifisch, mächtiger — Empfehlung)

### cert-manager für Let's Encrypt
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```
Danach einen `ClusterIssuer` für Let's Encrypt anlegen — dann bekommt jeder Service automatisch ein TLS-Zertifikat, analog zu deinem Certbot-Setup.

---

## Phase 3 — Storage mit Longhorn (Woche 2)

### Voraussetzungen auf dem Node
```bash
sudo apt install -y open-iscsi nfs-common util-linux
sudo systemctl enable --now iscsid
```

### Longhorn installieren
```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
```

Longhorn-UI ist dann erreichbar über einen Port-Forward:
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

### Konzepte

```yaml
# StorageClass (Longhorn als default setzen)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "1"   # → 2 sobald zweiter Node da ist
  staleReplicaTimeout: "2880"
```

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
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

### Single-Node-Betrieb: Backup statt Replikation

**Wichtig:** Solange der alte Raspi noch produktiv Docker-Services betreibt, kann er nicht gleichzeitig k3s Agent-Node sein. Das sind zwei unvereinbare Rollen. `numberOfReplicas: "1"` bleibt also so lange gesetzt, bis der alte Raspi vollständig aus dem Docker-Betrieb herausgenommen wurde.

Das bedeutet: **Im Single-Node-Betrieb ersetzt Backup die Replikation.**

Longhorn hat dafür eine native Lösung — Backups auf ein S3-kompatibles Ziel:

```
Longhorn Volume Snapshot → Longhorn Backup → Backblaze B2 / Hetzner Object Storage
```

Alternativ passt das bekannte Restic-Pattern aus dem docker-runtime-Setup:
```
Longhorn Volume → gemountetes Verzeichnis auf NVMe → Restic → externe HDD
```

Longhorn-native Backups sind die empfohlene Variante, da sie inkrementell und snapshot-basiert arbeiten und direkt über die Longhorn-UI geplant werden können.

### Weg zum zweiten Node

Wenn irgendwann alle Services auf k3s laufen und der alte Raspi aus dem Docker-Betrieb geht:
1. Docker stoppen, Daten sichern
2. Ubuntu neu aufsetzen (oder bestehendes OS nutzen)
3. k3s Agent installieren und dem Cluster joinen
4. `numberOfReplicas: "2"` in der Longhorn StorageClass setzen
5. Longhorn repliziert automatisch alle Volumes auf beide Nodes

---

## Phase 4 — Erste Migration: FreshRSS (Woche 3)

FreshRSS ist ideal als erster Kandidat:
- Ein einziges Volume (`./config`) — kein Datenbankcluster
- Kein komplexes Netzwerk-Setup
- Leicht rückgängig zu machen (Docker-Container läuft parallel weiter bis zum Cutover)

### Migrations-Strategie

```
1. FreshRSS in k3s deployen (leeres Volume)
2. Daten aus Docker-Volume nach Longhorn-PVC kopieren
3. Testen (parallel zum alten Container)
4. DNS/Traefik auf k3s umschalten
5. Docker-Container stoppen
```

### Daten-Migration (Docker → Longhorn PVC)

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
│   ├── longhorn/           ← Longhorn-Konfiguration
│   └── cert-manager/
├── infrastructure/
│   └── traefik/            ← Traefik-Konfiguration
└── docs/
```

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
# Controller im Cluster installieren
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

# CLI-Tool
curl -L https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-arm64.tar.gz | tar xz
sudo install kubeseal /usr/local/bin/
```

```bash
# Secret verschlüsseln → kann sicher ins Git-Repo
kubectl create secret generic freshrss-env \
  --from-literal=PASSWORD=geheim \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/freshrss/secret.yaml
```

Das resultierende `SealedSecret` kann gefahrlos in das öffentliche Repo committed werden. Nur der Cluster kann es entschlüsseln.

---

## Phase 7 — Monitoring (Woche 5)

```bash
# kube-prometheus-stack: Prometheus + Grafana + Alertmanager in einem Helm-Chart
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

Grafana läuft dann auf Port 3000 (über Ingress erreichbar). Vordefinierte Dashboards für Node-Metriken, Pod-Ressourcen etc. sind bereits dabei.

Für Raspberry Pi Hardware-Metriken (CPU-Temperatur etc.): `node_exporter` läuft bereits im kube-prometheus-stack.

---

## Phase 8 — Multi-Node: Alter Raspi hinzufügen (Zukunft)

**Voraussetzung:** Der alte Raspi läuft erst dann als k3s Agent-Node, wenn alle seine Docker-Services vollständig nach k3s migriert sind. Beide Rollen gleichzeitig sind nicht möglich.

Ablauf wenn es soweit ist:
1. Docker-Services stoppen, Daten sichern
2. k3s Agent auf dem alten Raspi installieren:

```bash
# Token vom Server-Node holen
sudo cat /var/lib/rancher/k3s/server/node-token

# Auf dem alten Raspi:
curl -sfL https://get.k3s.io | K3S_URL=https://<raspi5-ip>:6443 \
  K3S_TOKEN=<token> sh -
```

3. In der Longhorn StorageClass `numberOfReplicas: "2"` setzen → Longhorn repliziert alle Volumes automatisch auf beide Nodes.

**Node-Rollen:**
- **Server-Node** (Raspi 5): Control-Plane, API-Server, Scheduler, Etcd
- **Agent-Node** (alter Raspi): nur Workloads, kein Control-Plane

---

## Nicht-Ziele (bewusst ausgelassen)

- **High-Availability Control Plane**: Sinnvoll erst ab 3 Nodes. Für 2 Nodes reicht Single-Server-Setup.
- **Kubernetes-Dashboard**: Longhorn-UI und Grafana decken den Bedarf besser ab.
- **Multi-Cluster-Setups**: Nicht für diesen Use Case.

---

## Reihenfolge der nächsten Dokumente

1. `docs/01-os-setup.md` — NVMe-Boot, Ubuntu-Config, cgroups
2. `docs/02-k3s-install.md` — k3s, kubectl, erste Schritte
3. `docs/03-longhorn.md` — Storage einrichten
4. `apps/freshrss/` — FreshRSS Manifeste + Migrations-Anleitung
5. `docs/04-gitops-flux.md` — Flux setup
