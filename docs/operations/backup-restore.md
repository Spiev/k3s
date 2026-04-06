# Backup & Restore

## Überblick

Einheitliche Backup-Strategie via Restic für alle Services:

| Strategie | Tool | Services | Restore-Granularität |
|---|---|---|---|
| Datei-Backup | Restic → Hetzner S3 | Alle Services | einzelne Dateien, ganzer Service |

`local-path`-Volumes liegen direkt auf dem Node-Filesystem (`/var/lib/rancher/k3s/storage/<pvc-name>/`) — Restic kann sie direkt sichern ohne Snapshot-Mechanismus.

---

## Kritische Secrets außerhalb des Clusters

Diese Werte können **nicht** aus dem Cluster wiederhergestellt werden wenn etcd weg ist. Im Passwortmanager aufbewahren — unabhängig vom Cluster-Zustand:

| Secret | Exportieren | Aufbewahren |
|---|---|---|
| Sealed Secrets Key | `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml` | Passwortmanager |
| Hetzner S3 Credentials | Hetzner Console | Passwortmanager |
| Restic Repo-Passwort (S3) | aus `.restic.env` | Passwortmanager |

> `sealed-secrets-key.yaml` **nie ins Repo committen**.

---

## Restic Backup (alle Services)

### Funktionsweise

Das Backup-Script läuft als Cron-Job direkt auf dem Pi-Node und:
1. Verbindet sich per `kubectl exec` mit dem Datenbank-Pod und erstellt einen `pg_dumpall`-Dump
2. Kopiert Applikationsdaten per `kubectl cp` aus dem App-Pod
3. Sichert alles mit Restic in den Hetzner S3 Bucket
4. Meldet Status pro Service via MQTT an Home Assistant

Jeder Service bekommt einen eigenen HA-Sensor (`backup_paperless`, `backup_teslamate`, `backup_overall`).

### Einrichten

**Voraussetzung:** Hetzner S3 Bucket vorhanden (manuell in der Hetzner Cloud Console anlegen).

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

Reihenfolge nach Neuinstall: **Sealed Secrets → Services → Restic Restore**

1. Sealed Secrets Controller + Key einspielen
2. Service-Manifeste deployen: `kubectl apply -f apps/paperless/`
3. Warten bis Pods laufen
4. Restic Restore wie oben (Schritt 1–4)

---

## Restore — Restic (FreshRSS, Pi-hole)

FreshRSS und Pi-hole haben kein Datenbankprozess — ihre Daten sind Konfigurationsdateien auf dem local-path-Volume. Restore entspricht dem Restic-Restore oben, analog zu Paperless.

### FreshRSS wiederherstellen (Cluster läuft)

```bash
# 1. Deployment stoppen
kubectl scale deployment freshrss -n freshrss --replicas=0

# 2. Restic-Snapshot restoren
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" \
  restore latest --tag freshrss --target /tmp/restore

# 3. Daten zurückkopieren
kubectl cp /tmp/restore/var/lib/rancher/k3s/storage/freshrss-config/. \
  freshrss/$(kubectl get pod -n freshrss -l app=freshrss -o jsonpath='{.items[0].metadata.name}'):/config/

# 4. Deployment starten und verifizieren
kubectl scale deployment freshrss -n freshrss --replicas=1
rm -rf /tmp/restore
```

### Nach Cluster-Neuinstall

Reihenfolge: **Sealed Secrets → Services → Restic Restore**

1. Sealed Secrets Controller + Key einspielen
2. Service-Manifeste deployen: `kubectl apply -f apps/freshrss/`
3. Restic Restore wie oben

---

## Vor einem Cluster-Rebuild

Checkliste bevor der Cluster abgerissen wird:

```bash
# 1. Restic: letzten erfolgreichen Backup-Run prüfen
source ~/workspace/priv/k3s/scripts/.restic.env
RESTIC_PASSWORD="$RESTIC_PASSWORD_S3" restic -r "$RESTIC_REPO_S3" snapshots --last

# 2. Sealed Secrets Key exportieren
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.yaml
# → Im Passwortmanager sichern, nicht ins Repo committen
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
