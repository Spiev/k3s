# 04f — Paperless-ngx deployen & migrieren

Voraussetzung: [04e — Sealed Secrets](./04e-sealed-secrets.md) abgeschlossen.

Paperless-ngx enthält produktive Dokumente (Scans, OCR-Ergebnisse, Metadaten) — das Backup muss von Tag 1 funktionieren, bevor die Migration startet.

---

## Ausgangslage

**Docker-Setup (Pi1 / Agent-Node):**

```
paperless/
├── docker-compose.yml
├── postgres/              ← PostgreSQL 18 Datenverzeichnis (18/docker/...)
├── redisdata/             ← Redis (ephemer, kein Backup nötig)
└── library/
    ├── data/              ← Paperless interne Daten (search index, thumbnails)
    ├── media/             ← Dokumente & Anhänge (das Wichtigste!)
    ├── export/            ← Exports (regenerierbar)
    └── consume/           ← Eingangsordner (Inbox)
```

**5 Container:** `broker` (Redis), `db` (PostgreSQL 18), `webserver` (paperless-ngx), `gotenberg`, `tika`

**Aktuelles Backup** (`backup.sh`):
1. `docker exec paperless-db-1 pg_dumpall` → `.sql.gz` in `library/backup/`
2. `restic backup library/` → lokale USB-SSD auf Pi1
3. `restic copy` → Hetzner S3 (Offsite)
4. MQTT-Notification → Home Assistant

---

## Services & PVCs

| Container | Image | Persistent Storage | Backup |
|---|---|---|---|
| `broker` | `redis:8` | `redisdata` (klein) | nicht nötig (ephemer) |
| `db` | `postgres:18` | `paperless-postgres-enc` | pg_dumpall → media PVC |
| `webserver` | `paperless-ngx:2.20.13` | `paperless-media-enc`, `paperless-data-enc` | Restic CronJob |
| `gotenberg` | `gotenberg:8.28` | — (stateless) | — |
| `tika` | `apache/tika:3.2.3.0` | — (stateless) | — |

**PVCs (alle `longhorn-retain-encrypted`):**
- `paperless-postgres-enc` — PostgreSQL Daten
- `paperless-media-enc` — Dokumente & Anhänge (wichtigste Daten)
- `paperless-data-enc` — Paperless interne Daten (Search Index, Thumbnails)
- `paperless-redis-enc` — Redis (klein, optional)

---

## Backup-Strategie

### Grundüberlegung: Push, nicht Pull

Die USB-SSD (Restic-Repo) hängt an Pi1. Im Docker-Setup läuft `backup.sh` direkt auf Pi1 und greift auf lokale Bind-Mounts zu. In k3s liegen die Daten als Longhorn-PVCs auf Pi2 — kein direkter Host-Zugriff von Pi1 möglich.

**Warum Push (Pi2 → Pi1) statt Pull (Pi1 ← Pi2):**

| Modell | Pi1 kennt Key für Pi2? | Pi2 kennt Key für Pi1? | Risiko |
|---|---|---|---|
| Pull (Pi1 initiiert) | Ja | Nein | Pi1 kompromittiert → Pi2 angreifbar |
| **Push (Pi2 initiiert)** | **Nein** | **Ja (Backup-User)** | **Pi1 kompromittiert → Pi2 sicher** |

Pi1 hat viele Docker-Services (größere Angriffsfläche) → Pi1 darf keinen Key für Pi2 kennen.

### Restic SFTP-Backend: Push von Pi2 → Pi1

Restic unterstützt SFTP nativ als Repo-Backend. Der k3s-CronJob auf Pi2 schreibt direkt ins Restic-Repo auf der SSD via SFTP:

```
restic -r sftp:backup@pi1.fritz.box:/mnt/ssd/restic/paperless backup /media /data
```

**Kein Umzug der SSD nötig. Kein NFS. Kein komplexes Setup.**

Da Paperless (~10 GB) bereits im bestehenden Restic-Repo liegt (aus `backup.sh`), erkennt Restic beim ersten k3s-Backup dieselben Chunks → kaum Übertragung, auch auf WLAN (5 GHz) kein Problem. Folge-Backups transferieren nur neue/geänderte Dokumente.

### Eingeschränkter Backup-User auf Pi1

Pi1 bekommt einen dedizierten User `backup`. Der SSH-Key des CronJob-Pods darf **ausschließlich SFTP** — keine Shell, kein Port-Forwarding:

```
# /home/backup/.ssh/authorized_keys auf Pi1
command="internal-sftp",no-pty,no-agent-forwarding,no-port-forwarding ssh-ed25519 AAAA... k3s-backup
```

Worst case kompromittiertes Pi2: Angreifer kann ins Restic-Repo auf der SSD schreiben/lesen, aber Pi1 nicht übernehmen.

### SSD dauerhaft gemountet auf Pi1

`backup.sh` mountet die SSD aktiv und unmountet sie wieder. Damit Pi2's CronJob per SFTP schreiben kann, muss die SSD zum Backup-Zeitpunkt gemountet sein.

Lösung: **SSD dauerhaft in `/etc/fstab` eintragen** (`nofail`). Das aktive Mount/Unmount in `backup.sh` entfällt damit — die SSD ist immer verfügbar.

### Gesamtarchitektur

```
Pi2 — k8s CronJob (täglich 03:00)
  │
  ├─ 1. pg_dumpall → .sql.gz in media PVC (backup/ Subdir)
  │
  ├─ 2. restic backup /media /data
  │      → sftp:backup@pi1:/mnt/ssd/restic/paperless  (lokal, schnell)
  │
  ├─ 3. restic copy → Hetzner S3                       (offsite)
  │
  └─ 4. mosquitto_pub → MQTT → Home Assistant

Pi1
  └─ USB-SSD dauerhaft gemountet (/etc/fstab, nofail)
  └─ backup@ User: nur SFTP erlaubt (authorized_keys)
  └─ backup.sh läuft weiter (Immich, HA, Teslamate — unverändert)
```

**3-2-1 von Tag 1:**
```
Kopie 1: Longhorn PVC auf Pi2's NVMe
Kopie 2: USB-SSD auf Pi1 (via SFTP)
Kopie 3: Hetzner S3 (restic copy)
```

### CronJob: Referenzstruktur

```yaml
# apps/paperless/paperless-backup-cronjob.yaml (Entwurf — noch nicht finalisiert)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: paperless-backup
  namespace: paperless
spec:
  schedule: "0 3 * * *"   # täglich 03:00
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: restic/restic:0.18.0
              # Volumes: paperless-media-enc + paperless-data-enc gemountet
              # Env: RESTIC_REPOSITORY (sftp:...), RESTIC_PASSWORD aus Sealed Secret
              # SSH-Key für backup@pi1 als Secret gemountet (~/.ssh/id_ed25519)
              # Steps: pg_dumpall (Init-Container), restic backup, restic copy → S3, mosquitto_pub
```

> **TODO:** Konkretes CronJob-Manifest ausarbeiten wenn Migration startet. Postgres-Dump-Strategie klären: Init-Container der den Dump in die media-PVC schreibt ist am saubersten.

---

## Migrations-Reihenfolge

### Phase 0 — Backup sicherstellen (vor der Migration!)

1. Aktuelles `backup.sh` einmal manuell ausführen → sicherstellen dass Restic-Backup auf SSD und S3 aktuell ist
2. Prüfen: `restic snapshots` auf beiden Repos zeigt aktuelle Snapshots
3. `restic check` auf beiden Repos durchführen

### Phase 1 — Manifeste & Secrets

```bash
# Namespace + Secrets (Sealed Secret aus kubeseal)
# PostgreSQL Secret: POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
# Paperless Env: PAPERLESS_SECRET_KEY, PAPERLESS_DBPASS, ...
# Restic Backup Secret: RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
kubectl apply -f apps/paperless/
```

### Phase 2 — Daten migrieren

**PostgreSQL:** pg_dump auf Docker → pg_restore in k3s-Pod

```bash
# Dump auf Pi1
docker exec paperless-db-1 pg_dumpall -U paperless > paperless_migrate.sql

# Restore in k3s
kubectl cp paperless_migrate.sql paperless/<postgres-pod>:/tmp/
kubectl exec -n paperless <postgres-pod> -- psql -U paperless -f /tmp/paperless_migrate.sql
```

**Media & Data:** rsync von Pi1's Bind-Mounts in die Longhorn-PVCs via Migrationspod

```bash
# Temporärer Pod mit gemounteten Ziel-PVCs
# rsync über SSH: rsync -av pi1:/docker/paperless/library/media/ /media/
```

### Phase 3 — Backup-CronJob deployen & testen

```bash
kubectl apply -f apps/paperless/paperless-backup-cronjob.yaml

# Manuell auslösen:
kubectl create job -n paperless --from=cronjob/paperless-backup paperless-backup-test
kubectl logs -n paperless job/paperless-backup-test -f
```

Backup erfolgreich → Docker-Setup stoppen.

### Phase 4 — Docker stoppen

```bash
# Auf Pi1
cd /docker/paperless
docker compose down
```

---

## Offene Punkte

- [ ] Konkretes Manifest (`paperless.yaml`) ausarbeiten — Container-Config, Env-Vars, Service-Ports
- [ ] Restic-CronJob-Manifest finalisieren (Postgres-Dump-Strategie: Init-Container vs. `kubectl exec`)
- [ ] Ingress-Config (Traefik IngressRoute, LAN-only Middleware)
- [ ] Sealed Secrets für Paperless anlegen (DB-Passwort, Secret Key, Restic-Credentials)
- [ ] MQTT-Integration im CronJob: `mosquitto_pub` braucht Zugriff auf MQTT-Broker (HA-Namespace oder Mosquitto in k3s)
- [ ] Paperless-ngx ARM64 Support verifizieren (laut Upstream-Doku unterstützt, aber vor Migration kurz prüfen)
