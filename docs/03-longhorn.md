# 03 — Longhorn Storage

Voraussetzung: [02 — k3s installieren](./02-k3s-install.md) abgeschlossen, Cluster läuft.

Longhorn stellt persistente Volumes für alle Services bereit. Daten liegen direkt auf der NVMe des Raspberry Pi.

---

## 1. Voraussetzungen auf dem Node

Longhorn benötigt einige Pakete auf dem Host:

```bash
sudo apt install -y open-iscsi nfs-common cryptsetup
sudo systemctl enable --now iscsid
```

| Paket | Warum |
|---|---|
| `open-iscsi` | Longhorn kommuniziert intern über iSCSI mit seinen Volumes |
| `nfs-common` | Für RWX-Volumes (ReadWriteMany, mehrere Pods gleichzeitig) |
| `cryptsetup` | Volume-Verschlüsselung (optional, aber Longhorn prüft auf dessen Existenz) |

**Voraussetzungen automatisch prüfen** — Longhorn bringt ein Check-Script mit:

```bash
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/master/scripts/environment_check.sh | bash
```

Alle Punkte sollten grün sein bevor es weitergeht.

---

## 2. Longhorn installieren

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
```

Die Installation dauert 2–3 Minuten. Fortschritt beobachten:

```bash
kubectl get pods -n longhorn-system -w
# Alle Pods müssen Running erreichen, keiner darf in CrashLoopBackOff landen
```

Wenn alle Pods laufen:

```bash
kubectl get storageclass
# NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE
# longhorn (default)   driver.longhorn.io   Delete          Immediate
# local-path           ...                  Delete          WaitForFirstConsumer
```

Longhorn setzt sich automatisch als Default-StorageClass. Das ist korrekt.

---

## 3. Longhorn UI

Die Weboberfläche über einen Port-Forward erreichbar machen:

```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

Browser: `http://localhost:8080`

Von einem anderen Rechner im Netzwerk (z.B. vom Laptop):
```bash
ssh -L 8080:localhost:8080 stefan@raspi
# Dann: http://localhost:8080 im Browser auf dem Laptop
```

Die UI zeigt:
- **Node** — Raspi mit verfügbarem Disk-Speicher
- **Volumes** — alle PVCs und ihr Status
- **Backups** — konfigurierte Backup-Ziele und -Historie
- **Settings** — globale Longhorn-Konfiguration

> Später wird die UI über Traefik dauerhaft erreichbar gemacht (mit Auth). Für jetzt reicht Port-Forward.

---

## 4. StorageClass konfigurieren

Die Default-StorageClass von Longhorn für Single-Node anpassen:

```yaml
# infrastructure/longhorn/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain      # Retain statt Delete: Volume bleibt bei PVC-Löschung erhalten
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"             # Single-Node: 1 Replica
  staleReplicaTimeout: "2880"       # Verwaiste Replicas nach 48h aufräumen
  fromBackup: ""
  fsType: "ext4"
```

```bash
kubectl apply -f infrastructure/longhorn/storageclass.yaml
```

**Warum `reclaimPolicy: Retain`?**
Mit `Delete` (Longhorn-Default) wird ein Volume sofort gelöscht wenn sein PVC gelöscht wird — auch bei einem versehentlichen `kubectl delete`. `Retain` lässt das Volume bestehen, es muss dann manuell in der Longhorn-UI entfernt werden. Für Produktionsdaten die sicherere Wahl.

---

## 5. Konzepte: PVC und PV

Pods sprechen nie direkt mit Longhorn. Der Weg ist immer:

```
Pod  →  PVC (Anforderung)  →  PV (tatsächlicher Speicher, von Longhorn bereitgestellt)
```

**PVC anlegen** (Beispiel FreshRSS):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce     # RWO: nur ein Pod gleichzeitig (Standard für die meisten Services)
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

**Access Modes:**

| Mode | Abkürzung | Bedeutung | Wann nutzen |
|---|---|---|---|
| ReadWriteOnce | RWO | Ein Pod liest/schreibt | Fast immer (FreshRSS, MariaDB, …) |
| ReadWriteMany | RWX | Mehrere Pods gleichzeitig | Shared Media-Verzeichnisse |
| ReadOnlyMany | ROX | Mehrere Pods lesen | Selten |

**Volume in einem Deployment nutzen:**

```yaml
spec:
  containers:
    - name: freshrss
      volumeMounts:
        - name: config
          mountPath: /config          # Pfad im Container
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: freshrss-config    # Name des PVC oben
```

---

## 6. Backup-Strategie (Single-Node)

Im Single-Node-Betrieb gibt es keine Replikation — Backup ist daher kritisch.

Longhorn unterstützt Backups auf S3-kompatible Ziele. **Empfehlung: Backblaze B2** (günstig, S3-kompatibel, europäische Rechenzentren verfügbar).

### Backup-Ziel konfigurieren

```bash
# Credentials als Secret anlegen
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID=<b2-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<b2-application-key> \
  --from-literal=AWS_ENDPOINTS=https://s3.eu-central-003.backblazeb2.com
```

In der Longhorn UI unter **Settings → Backup**:
- `Backup Target`: `s3://dein-bucket-name@eu-central-003/`
- `Backup Target Credential Secret`: `longhorn-backup-secret`

### Backup-Plan für Volumes

In der Longhorn UI unter **Recurring Jobs**:

```
Name:       daily-backup
Task:       backup
Cron:       0 2 * * *    (täglich 2:00 Uhr)
Retain:     7            (7 Backups aufbewahren)
```

Diesen Job dann jedem Volume zuweisen — oder als Default für alle neuen Volumes setzen.

### Snapshot vs. Backup

```
Snapshot  →  liegt auf demselben Node (schnell, kein Schutz vor Hardware-Ausfall)
Backup    →  liegt extern auf B2/S3 (langsamer, aber echter Schutz)
```

Für Produktion: tägliche Backups extern + stündliche Snapshots lokal.

---

## 7. Erstes Volume testen

Einen temporären Pod mit einem PVC starten und prüfen ob Longhorn funktioniert:

```bash
kubectl create namespace longhorn-test

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: longhorn-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: longhorn-test
spec:
  containers:
    - name: test
      image: alpine
      command: ["sh", "-c", "echo 'Longhorn works!' > /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-pvc
EOF
```

```bash
# Pod läuft?
kubectl get pod -n longhorn-test test-pod

# Datei im Volume?
kubectl exec -n longhorn-test test-pod -- cat /data/test.txt
# → Longhorn works!

# Volume in der Longhorn UI sichtbar?
# → http://localhost:8080 → Volumes → test-pvc sollte Attached sein
```

Aufräumen:
```bash
kubectl delete namespace longhorn-test
```

Das Volume bleibt in der Longhorn UI als `Detached` sichtbar (wegen `reclaimPolicy: Retain`) und muss dort manuell gelöscht werden.

---

## 8. Abschluss-Check

```bash
# Longhorn Pods alle Running
kubectl get pods -n longhorn-system

# Default StorageClass ist Longhorn
kubectl get storageclass
# longhorn (default)

# Node hat verfügbaren Speicher (Longhorn UI oder):
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
STORAGE:.status.allocatable.ephemeral-storage

# Backup-Ziel konfiguriert und erreichbar
# → Longhorn UI → Settings → Backup Target Status: Available
```

---

## Weiter: [04 — FreshRSS deployen](./04-freshrss.md)
