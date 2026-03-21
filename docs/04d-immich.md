# Immich Migration: Docker → k3s

Immich ist aufgrund der Datenmenge der komplexeste Migrations-Kandidat. Diese Anleitung beschreibt die Strategie und den konkreten Ablauf.

---

## Ausgangslage & Constraints

Immich läuft auf dem Agent-Node (2 TB NVMe) mit einer Bibliothek von ~1.5 TB. Der Agent-Node muss für den k3s-Join neu installiert werden — Docker und k3s können nicht parallel betrieben werden.

**Das Problem:**
```
NVMe (1.8T gesamt):  ~1.6T belegt, ~200G frei
  └── Immich library:  ~1.5 TB
  └── alle anderen Services: ~12 GB
Externe SSD:         ~393G frei  (zu wenig für 1.5T)
```

Ein klassischer Migration-Pod (altes Volume → neues Longhorn-PVC kopieren) scheidet aus — dafür fehlt ~1.5 TB freier Speicher auf derselben Platte.

---

## Strategie: Restic-Restore nach Neuinstall

Der Agent-Node wird neu installiert (NVMe wird dabei gewischt). Danach stehen ~1.8 TB frei zur Verfügung — genug für das Longhorn-PVC + Restore der Immich-Bibliothek aus dem Restic-Backup.

Das Restic-Backup enthält:
- Immich library (Fotos/Videos)
- PostgreSQL-Dump (via Immich's eingebautem Backup-Worker, landet im library-Verzeichnis)

```
Externe SSD (Restic-Repo)
        │
        │  restic restore
        ▼
Frisch installierter Agent-Node
  └── Longhorn PVC (1.6T+, auf NVMe)
        │
        ▼
Immich deployment in k3s
```

---

## Reihenfolge

### Phase 1 — Voraussetzungen schaffen

1. **Alle anderen Docker-Services zuerst migrieren:** Pi-hole, Teslamate, Home Assistant, Paperless (zusammen ~12 GB — unkritisch für den Speicher)
2. **S3-Offsite-Backup sicherstellen:** Restic läuft bereits lokal auf externe SSD. Vor der Migration sicherstellen, dass das Offsite-Backup ebenfalls aktuell ist → zwei unabhängige Kopien
3. **Backup-Integrität prüfen:**
   ```bash
   restic -r <repo-pfad> check --read-data
   ```
   `--read-data` ist wichtig — ohne dieses Flag prüft Restic nur Metadaten, nicht die eigentlichen Daten. Bei ~1.5 TB dauert das eine Weile.
4. **Letztes Backup vor dem Wipe** manuell triggern

### Phase 2 — Agent-Node neu aufsetzen

1. Raspberry Pi OS Lite (64-bit, Bookworm) auf NVMe flashen
2. cgroups aktivieren, Swap deaktivieren (→ [01-os-setup.md](./01-os-setup.md))
3. k3s Agent installieren und dem Cluster joinen (→ [learning-path.md Phase 8](./learning-path.md))
4. Longhorn erkennt den neuen Node automatisch

### Phase 3 — Longhorn PVC anlegen

PVC auf dem Agent-Node platzieren (via Node-Selector / Longhorn-Tag):

```yaml
# In apps/immich/immich.yaml
# PVC mit nodeSelector auf Agent-Node
# Größe: mindestens aktuelle Library-Größe + Puffer (z.B. 1800Gi)
```

> Solange Single-Node: `numberOfReplicas: "1"`, nach zweitem Node: `"2"`

### Phase 4 — Restore aus Restic

Temporären Restore-Pod deployen, der PVC + externe SSD mountet:

```yaml
# restore-pod.yaml (wird nach Restore gelöscht, nicht committed)
volumes:
  - name: immich-data
    persistentVolumeClaim:
      claimName: immich-library
  - name: backup-ssd
    hostPath:
      path: /mnt/sda1   # externe SSD am Agent-Node
```

Im Pod:
```bash
restic -r /backup/restic-repo restore latest \
  --target /data \
  --include '**/immich/library'
```

### Phase 5 — Immich deployen & verifizieren

1. Restore-Pod löschen
2. Immich deployen (server, machine-learning, redis, postgres)
3. Im Immich-UI: Admin → Jobs → "Library Scan" ausführen
4. Stichproben: Ein paar Alben, Faces, Suche prüfen
5. Traefik IngressRoute aktivieren, DNS/nginx umschalten
6. Externe SSD kann danach als reines Backup-Target weitergenutzt werden

---

## Stack-Übersicht (4 Container)

| Container | Image | Zweck |
|---|---|---|
| immich-server | `ghcr.io/immich-app/immich-server` | API + Web-UI |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning` | Gesichtserkennung, CLIP-Suche |
| redis | `docker.io/valkey/valkey:8-bookworm` | Cache & Queue |
| postgres | `ghcr.io/immich-app/postgres:16-vectorchord...` | DB mit pgvectors-Extension |

> Postgres-Image ist Immich-spezifisch (enthält VectorChord/pgvectors) — kein Standard-PostgreSQL-Image verwenden.

**Volumes:**
- `immich-library` PVC → `/usr/src/app/upload` im immich-server
- `immich-postgres` PVC → `/var/lib/postgresql/data`
- `model-cache` PVC → `/cache` im machine-learning Container

**Secrets (Sealed Secrets):**
- `DB_PASSWORD`
- `DB_USERNAME`, `DB_DATABASE_NAME`

---

## Risiken & Absicherung

| Risiko | Absicherung |
|---|---|
| Restic-Restore schlägt fehl | `restic check --read-data` vorher + S3-Offsite als zweite Kopie |
| Restore unvollständig | Test-Restore eines Ordners vor dem Wipe |
| Postgres-Dump fehlt/veraltet | Immich-Backup-Job im UI prüfen: Admin → Jobs → "Database Backup" |
| Longhorn PVC zu klein | Aktuellen Verbrauch vor Migration messen: `du -sh ~/docker/immich/library` |

---

## Abhängigkeiten

- Alle anderen Docker-Services müssen zuerst migriert sein (Agent-Node muss frei sein für Neuinstall)
- Sealed Secrets muss eingerichtet sein (→ Phase 6 im learning-path)
- Flux CD optional, aber empfohlen bevor Immich migriert wird
