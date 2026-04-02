# 09 — Backup & Restore

## Überblick

Zwei Backup-Strategien parallel im Einsatz:

| Strategie | Tool | Services | Restore-Granularität |
|---|---|---|---|
| Volume-Snapshot | Longhorn → S3 | FreshRSS (kein DB) | ganzes Volume |
| Datei-Backup | Restic → Hetzner S3 | Paperless, Teslamate | einzelne Dateien, ganzer Service |

> **Longhorn-Backups sind kein Ersatz für Restic bei DB-Services.** Longhorn sichert auf Block-Ebene (crash-consistent). Für Postgres-Datenbanken ist ein logischer Dump (`pg_dumpall`) zwingend — nur so ist ein konsistenter Restore garantiert. Siehe [Bekannte Limitierungen](#bekannte-limitierungen-longhorn).

---

## Kritische Secrets außerhalb des Clusters

Diese Werte können **nicht** aus dem Cluster wiederhergestellt werden wenn etcd weg ist. Im Passwortmanager aufbewahren — unabhängig vom Cluster-Zustand:

| Secret | Exportieren | Aufbewahren |
|---|---|---|
| Longhorn Crypto Key | siehe unten | Passwortmanager |
| Sealed Secrets Key | `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml` | Passwortmanager |
| Hetzner S3 Credentials | Hetzner Console | Passwortmanager |
| Restic Repo-Passwort (S3) | aus `.restic.env` | Passwortmanager |

```bash
# Longhorn Crypto Key exportieren:
kubectl get secret longhorn-crypto-secret -n longhorn-system \
  -o jsonpath='{.data.CRYPTO_KEY_VALUE}' | base64 -d
```

> `sealed-secrets-key.yaml` und den Crypto Key **nie ins Repo committen**.

---

## Teil 1 — Longhorn Backup (FreshRSS)

Longhorn erstellt täglich Volume-Snapshots und kopiert diese in den Hetzner S3 Bucket. Für FreshRSS (kein Datenbankprozess, nur Konfigurationsdateien) ist das ausreichend.

### Hetzner Object Storage einrichten

> Kein offizieller Terraform-Provider für Hetzner Object Storage — Bucket manuell anlegen.

**Bucket anlegen** in der [Hetzner Cloud Console](https://console.hetzner.cloud):
1. Projekt → **Object Storage** → **Bucket erstellen**
2. Location: `nbg1` (Nuremberg) empfohlen
3. Name: `bkp-home` (oder eigener Name)
4. Sichtbarkeit: **Private**

**Access Key erstellen:**
1. **Object Storage** → **Access Keys** → **Access Key erstellen**
2. Name: `longhorn-backup`
3. Access Key ID und Secret Key notieren — Secret Key nur einmalig sichtbar

**Longhorn Backup-Target konfigurieren:**

```bash
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="<hetzner-access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<hetzner-secret-key>" \
  --from-literal=AWS_ENDPOINTS=https://nbg1.your-objectstorage.com
```

In der Longhorn UI unter **Settings → Backup**:
- `Backup Target`: `s3://bkp-home@nbg1/`
- `Backup Target Credential Secret`: `longhorn-backup-secret`

Nach dem Speichern sollte **Backup Target Status: Available** erscheinen.

**Backup-Plan einrichten** unter **Recurring Jobs**:

```
Name:    daily-backup
Task:    backup
Cron:    0 2 * * *    (täglich 2:00 Uhr)
Retain:  7
```

Job dem FreshRSS-Volume zuweisen (oder als Default für alle Volumes setzen).

### Bekannte Limitierungen Longhorn

**Crash-Consistency:** Longhorn sichert rohe LUKS-Blöcke — nicht den entschlüsselten Inhalt. Für Services mit laufenden Datenbankprozessen ist das nicht ausreichend.

**Verschlüsselte Volumes:** Backup eines verschlüsselten Volumes enthält LUKS-Blöcke. Restore auf unverschlüsseltes Volume → nicht mountbar. Restore auf verschlüsseltes Volume → nur mit korrektem Crypto Key.

**`fromBackup`-Annotation** funktioniert nicht mit verschlüsselten StorageClasses ([Longhorn Issue #9571](https://github.com/longhorn/longhorn/issues/9571)) — PVs immer manuell anlegen.

**Silent Failures:** Longhorn meldet fehlgeschlagene S3-Backups nicht aktiv in der UI. Stand 2026: Issue [#3537](https://github.com/longhorn/longhorn/issues/3537) noch offen (Teilverbesserungen in v1.7.0 und v1.11.1).

---

## Teil 2 — Restic Backup (Paperless, Teslamate)

### Funktionsweise

Das Backup-Script läuft als Cron-Job direkt auf dem Pi-Node und:
1. Verbindet sich per `kubectl exec` mit dem Datenbank-Pod und erstellt einen `pg_dumpall`-Dump
2. Kopiert Applikationsdaten per `kubectl cp` aus dem App-Pod
3. Sichert alles mit Restic in den Hetzner S3 Bucket
4. Meldet Status pro Service via MQTT an Home Assistant

Jeder Service bekommt einen eigenen HA-Sensor (`backup_paperless`, `backup_teslamate`, `backup_overall`).

### Einrichten

**Voraussetzung:** Hetzner S3 Bucket bereits vorhanden (aus Longhorn-Setup oder separater Bucket).

**Restic auf dem Pi-Node installieren:**

```bash
# Aktuelle Version prüfen: https://github.com/restic/restic/releases
RESTIC_VERSION="0.17.3"
wget "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_arm64.bz2"
bunzip2 "restic_${RESTIC_VERSION}_linux_arm64.bz2"
sudo mv "restic_${RESTIC_VERSION}_linux_arm64" /usr/local/bin/restic
sudo chmod +x /usr/local/bin/restic
restic version
```

**mosquitto-clients installieren** (für MQTT-Benachrichtigungen):

```bash
sudo apt install mosquitto-clients
```

**Script einrichten:**

```bash
cd ~/workspace/priv/k3s/scripts

cp backup.sh.example backup.sh
chmod 700 backup.sh

cp .restic.env.example .restic.env
chmod 600 .restic.env
# .restic.env mit eigenen Werten befüllen

cp .mqtt_credentials.example .mqtt_credentials
chmod 600 .mqtt_credentials
# .mqtt_credentials mit MQTT_USER und MQTT_PASSWORD befüllen
```

**Restic S3-Repo initialisieren** (einmalig):

```bash
source .restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" init
```

**Cron-Job einrichten:**

```bash
crontab -e
```

Eintrag:
```
30 2 * * * /home/stefan/workspace/priv/k3s/scripts/backup.sh >> /var/log/k3s-backup.log 2>&1
```

**Ersten Backup-Lauf testen:**

```bash
~/workspace/priv/k3s/scripts/backup.sh
```

Prüfen ob Snapshots vorhanden:
```bash
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots
```

### Neuen Service hinzufügen

Wenn ein weiterer Service zu k3s migriert wird:
1. In `scripts/.restic.env` den Service zu `BACKUP_SERVICES` hinzufügen
2. In `scripts/backup.sh` eine `backup_<service>()`-Funktion ergänzen (analog zu `backup_paperless`)
3. Die Funktion im `case`-Block unten registrieren

### Home Assistant Dashboard

Für jeden Service und den Overall-Status erscheint automatisch ein Sensor in HA (via MQTT Discovery). Beispiel-Card für das Dashboard:

```yaml
type: entities
title: Restic Backup
entities:
  - entity: sensor.backup_overall
  - entity: sensor.backup_paperless
  - entity: sensor.backup_teslamate
```

---

## Restore — Restic

### Verfügbare Snapshots anzeigen

```bash
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots
```

Mit Filter nach Service:
```bash
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --tag paperless
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --tag teslamate
```

### Einzelne Datei / Verzeichnis wiederherstellen

```bash
# Snapshot-ID aus `restic snapshots` ermitteln, z.B. abc12345
SNAPSHOT="abc12345"

# Inhalt eines Snapshots auflisten
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  ls "$SNAPSHOT"

# Einzelne Datei / Verzeichnis in /tmp restoren
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore "$SNAPSHOT" \
  --include "/tmp/k3s-backup/paperless/media/documents/originals/2025/01/rechnung.pdf" \
  --target /tmp/restore
```

### Ganzen Service wiederherstellen (Cluster läuft)

**Schritt 1 — Staging-Verzeichnis aus Restic wiederherstellen:**

```bash
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest \
  --tag paperless \
  --target /tmp/restore
```

Das staging-Verzeichnis liegt unter `/tmp/restore/tmp/k3s-backup/paperless/`.

**Schritt 2 — DB-Dump in den laufenden DB-Pod einspielen:**

```bash
# Service stoppen (verhindert Schreibkonflikte während des Restores)
kubectl scale deployment paperless -n paperless --replicas=0
kubectl scale deployment paperless-db -n paperless --replicas=0

# Warten bis Pods weg sind
kubectl wait --for=delete pod -n paperless -l app=paperless --timeout=60s

# DB-Pod wieder starten (ohne App)
kubectl scale deployment paperless-db -n paperless --replicas=1
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless-db --timeout=60s

# Dump einspielen
DB_POD=$(kubectl get pod -n paperless -l app=paperless-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/restore/tmp/k3s-backup/paperless/paperless_db_*.sql.gz \
  | kubectl exec -i -n paperless "$DB_POD" -- psql -U paperless
```

**Schritt 3 — Media-Dateien zurückkopieren:**

```bash
# App-Pod starten
kubectl scale deployment paperless -n paperless --replicas=1
kubectl wait --for=condition=Ready pod -n paperless -l app=paperless --timeout=90s

APP_POD=$(kubectl get pod -n paperless -l app=paperless -o jsonpath='{.items[0].metadata.name}')

# Media-Verzeichnis zurückkopieren
kubectl cp /tmp/restore/tmp/k3s-backup/paperless/media \
  "paperless/$APP_POD:/usr/src/paperless/media"
```

**Schritt 4 — Verifizieren:**

Im Paperless-UI prüfen ob Dokumente und Tags korrekt sind.

```bash
# Aufräumen
rm -rf /tmp/restore
```

### Ganzen Service wiederherstellen (nach Cluster-Neuinstall)

Reihenfolge nach Neuinstall: **Longhorn → Sealed Secrets → Services → Restic Restore**

1. Longhorn Backup-Target konfigurieren (siehe [Restore nach Cluster-Neuinstall](#restore-nach-cluster-neuinstall-longhorn))
2. Sealed Secrets Controller + Key einspielen
3. Service-Manifeste deployen: `kubectl apply -f apps/paperless/`
4. Warten bis Pods laufen
5. Restic Restore wie oben (Schritt 1–4)

---

## Restore — Longhorn (FreshRSS)

### Restore nach Cluster-Neuinstall

Reihenfolge: **Longhorn → Backup-Target → Crypto Key → Sealed Secrets → Services**

**Schritt 1 — Longhorn Backup-Target konfigurieren:**

```bash
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="<hetzner-access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<hetzner-secret-key>" \
  --from-literal=AWS_ENDPOINTS=https://nbg1.your-objectstorage.com
```

In der Longhorn UI unter **Settings → Backup**:
- `Backup Target`: `s3://bkp-home@nbg1/`
- `Backup Target Credential Secret`: `longhorn-backup-secret`

Unter **Backup** prüfen ob die alten Backups erscheinen — Longhorn liest sie automatisch aus dem Bucket.

**Schritt 2 — Longhorn Crypto Key wiederherstellen:**

```bash
kubectl create secret generic longhorn-crypto-secret \
  -n longhorn-system \
  --from-literal=CRYPTO_KEY_VALUE="<key-aus-passwortmanager>" \
  --from-literal=CRYPTO_KEY_PROVIDER=secret
```

**Schritt 3 — Sealed Secrets Controller + Key:**

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/<version>/controller.yaml

# Alten Schlüssel VOR dem ersten SealedSecret-Deploy einspielen
kubectl apply -f sealed-secrets-key.yaml
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

### FreshRSS aus Longhorn-Backup wiederherstellen

#### Variante A — Backup stammt von verschlüsseltem Volume (Normalfall)

**Longhorn UI → Backup → freshrss-config → letztes Backup → Restore:**
- Volume-Name: `freshrss-config-restored`
- Encrypted: **angehakt**
- Secret Namespace: `longhorn-system`
- Secret Name: `longhorn-crypto-secret`
- Data Engine: `v1`
- Access Mode: `ReadWriteOnce`

Warten bis Status `Ready for workload` unter **Volumes**.

> **Single-Node:** Longhorn setzt beim UI-Restore die Default-Replica-Anzahl (3). Direkt danach auf 1 reduzieren:
> ```bash
> kubectl patch volume freshrss-config-restored -n longhorn-system \
>   --type=merge -p '{"spec":{"numberOfReplicas":1}}'
> ```

**PV manuell anlegen** (mit Secret-Refs — ohne diese kann kubelet das LUKS-Volume nicht entschlüsseln):

```yaml
# /tmp/freshrss-pv-restore.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: freshrss-config-restored
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-retain-encrypted
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: freshrss-config-restored
    nodeStageSecretRef:
      name: longhorn-crypto-secret
      namespace: longhorn-system
    nodePublishSecretRef:
      name: longhorn-crypto-secret
      namespace: longhorn-system
```

```bash
kubectl apply -f /tmp/freshrss-pv-restore.yaml
```

**PVC anlegen:**

```yaml
# /tmp/freshrss-pvc-restore.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-retain-encrypted
  volumeName: freshrss-config-restored
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl create namespace freshrss --save-config
kubectl apply -f /tmp/freshrss-pvc-restore.yaml
kubectl get pvc -n freshrss -w
# Warten bis STATUS=Bound
```

**Service deployen und verifizieren:**

```bash
kubectl apply -f apps/freshrss/freshrss.yaml
kubectl get pods -n freshrss -w
# Warten bis 1/1 Running
```

Feeds, Read-Status und Settings im Browser prüfen.

#### Variante B — Backup stammt von unverschlüsseltem Volume

Selber Ablauf wie Variante A, aber:
- Restore in Longhorn UI: **Encrypted nicht angehakt**
- PV anlegen **ohne** Secret-Refs, `storageClassName: longhorn-retain`
- PVC mit `storageClassName: longhorn-retain`

Danach optional Migration auf verschlüsseltes Volume (siehe [Volume-Migration](#volume-migration-unveschlüsselt-→-verschlüsselt)).

### Einzelnen Service wiederherstellen (Cluster läuft)

```bash
# 1. Deployment stoppen
kubectl scale deployment freshrss -n freshrss --replicas=0

# 2. PVC löschen (Longhorn-Volume bleibt wegen Retain-Policy erhalten)
kubectl delete pvc freshrss-config -n freshrss
```

Danach den Restore-Prozess wie oben durchlaufen (Longhorn UI → PV → PVC → Deployment).

### Volume-Migration: unverschlüsselt → verschlüsselt

Nach einem Restore aus einem unverschlüsselten Backup die Daten in ein verschlüsseltes Volume migrieren:

```bash
# 1. Migrations-Pod starten der beide Volumes mountet
```

```yaml
# /tmp/freshrss-migration-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: freshrss-migration
  namespace: freshrss
spec:
  containers:
    - name: migration
      image: alpine:3.21
      command: ["sh", "-c", "cp -av /source/. /dest/ && echo 'Migration done' && sleep 3600"]
      volumeMounts:
        - name: source
          mountPath: /source
        - name: dest
          mountPath: /dest
  volumes:
    - name: source
      persistentVolumeClaim:
        claimName: freshrss-config          # unverschlüsselt (restored)
    - name: dest
      persistentVolumeClaim:
        claimName: freshrss-config-encrypted  # neu, longhorn-retain-encrypted
```

```bash
# Neues verschlüsseltes PVC anlegen (aus dem Service-Manifest)
kubectl apply -f apps/freshrss/freshrss.yaml  # legt freshrss-config-encrypted an

kubectl apply -f /tmp/freshrss-migration-pod.yaml
kubectl logs -n freshrss freshrss-migration -f
# Warten auf "Migration done"

# 2. Service auf verschlüsseltes Volume umstellen
kubectl scale deployment freshrss -n freshrss --replicas=0
kubectl patch deployment freshrss -n freshrss \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"freshrss-config-encrypted"}]'
kubectl scale deployment freshrss -n freshrss --replicas=1

# 3. Aufräumen
kubectl delete pod freshrss-migration -n freshrss
kubectl delete pvc freshrss-config -n freshrss
kubectl delete pv freshrss-config-restored
# Longhorn UI: freshrss-config-restored Volume löschen
```

---

## Vor einem Cluster-Rebuild

Checkliste bevor der Cluster abgerissen wird:

```bash
# 1. Longhorn: aktuellen Backup-Status prüfen
#    Longhorn UI → Backup → alle Volumes müssen State: Completed haben
#    Falls nicht: manuellen Backup-Job triggern

# 2. Restic: letzten erfolgreichen Backup-Run prüfen
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --last

# 3. Sealed Secrets Key exportieren
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.yaml
# → Im Passwortmanager sichern, nicht ins Repo committen

# 4. Longhorn Crypto Key notieren (im Passwortmanager)
kubectl get secret longhorn-crypto-secret -n longhorn-system \
  -o jsonpath='{.data.CRYPTO_KEY_VALUE}' | base64 -d
```

---

## Troubleshooting

```bash
# Restic: Snapshot-Details anzeigen
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --verbose

# Restic: Repository-Integrität prüfen
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" check

# Restic: Stale Locks entfernen (nach abgebrochenem Backup)
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" unlock

# kubectl exec funktioniert nicht?
#   → kubectl muss auf dem Node als der Cron-User erreichbar sein
#   → KUBECONFIG prüfen: echo $KUBECONFIG (oder Default /etc/rancher/k3s/k3s.yaml)
kubectl get pods -n paperless

# Backup-Log einsehen
tail -100 /var/log/k3s-backup.log
```

---

## Hinweis: nginx resolver.conf bei Dual-Stack (FreshRSS)

Das linuxserver.io FreshRSS-Image generiert `/config/nginx/resolver.conf` beim ersten Start. In einem Dual-Stack-Cluster enthält diese Datei IPv6-Adressen ohne eckige Klammern — nginx lehnt das ab:

```
invalid port in resolver "fd43::a"
```

Fix — einmalig nach dem ersten Start ausführen:

```bash
kubectl exec -n freshrss <pod-name> -- sh -c \
  'echo "resolver 10.43.0.10 valid=30s;" > /config/nginx/resolver.conf'
kubectl rollout restart deployment freshrss -n freshrss
```

Da die Datei in `/config` (persistentes Volume) liegt und nur beim ersten Start generiert wird, ist dieser Fix dauerhaft.
