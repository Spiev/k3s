# 04c — Seafile deployen

Voraussetzung: [04a — FreshRSS](./04a-freshrss.md) abgeschlossen. Sealed Secrets sollten vor diesem Schritt eingerichtet sein (Secrets für DB-Passwort und Seafile SECRET_KEY).

Seafile ist der zweite Migrationskanditat und deutlich komplexer als FreshRSS: zwei Pods, zwei Volumes, Service-to-Service-Kommunikation und Secrets. Das macht es zum idealen Lernschritt vor GitOps.

---

## Architektur

```
[Ingress/Traefik]
      │  Host: seafile.example.com
      ▼
[Service: seafile]  →  [Pod: seafile-mc]
                              │  mariadb.seafile.svc.cluster.local:3306
                              ▼
                    [Service: mariadb]  →  [Pod: mariadb]
                                                │
                              ┌─────────────────┘
                              ▼
                    [PVC: mariadb-data]   [PVC: seafile-data]
                    (Longhorn)            (Longhorn)
```

`seafile-mc` (das offizielle Image) enthält Seafile, Seahub **und** memcached in einem Container. Dadurch bleibt es bei zwei Pods statt vier.

---

## Neue Konzepte gegenüber FreshRSS

| Konzept | Warum hier relevant |
|---|---|
| Mehrere Deployments in einem Namespace | Seafile + MariaDB als getrennte Workloads |
| Service-to-Service-Kommunikation | Seafile spricht MariaDB via CoreDNS an |
| Sealed Secrets | DB-Passwort und Seafile `SECRET_KEY` müssen verschlüsselt im Repo liegen |
| Startup-Abhängigkeit | MariaDB muss bereit sein bevor Seafile startet |
| StatefulSet vs. Deployment | Datenbanken wollen stabile Pod-Namen → MariaDB als StatefulSet |

---

## Übersicht der Manifeste (geplant)

```
apps/seafile/
├── namespace.yaml
├── pvc-seafile.yaml          ← /shared/seafile (Datei-Blobs)
├── pvc-mariadb.yaml          ← /var/lib/mysql
├── statefulset-mariadb.yaml  ← MariaDB als StatefulSet
├── service-mariadb.yaml      ← ClusterIP, nur intern erreichbar
├── deployment-seafile.yaml   ← seafile-mc Container
├── service-seafile.yaml      ← ClusterIP → Ingress
├── ingress.yaml              ← Domain-Routing
└── sealed-secret.yaml        ← DB-Passwort + SECRET_KEY (verschlüsselt)
```

---

## Warum MariaDB als StatefulSet?

Deployments erstellen Pods mit zufälligen Namen (`mariadb-7d9f4b-xxxx`). Bei einem Neustart bekommt der Pod einen neuen Namen — für zustandslose Apps kein Problem, für Datenbanken aber ungünstig: das Volume-Mounting kann instabil werden.

StatefulSets vergeben stabile, vorhersehbare Namen (`mariadb-0`) und garantieren eine definierte Startreihenfolge. Standard-Praxis für Datenbanken in Kubernetes.

---

## Startup-Reihenfolge: MariaDB vor Seafile

Seafile schlägt beim Start fehl wenn MariaDB noch nicht bereit ist. Zwei Wege das zu lösen:

**Option A — `initContainer`** (empfohlen): Ein leichter Init-Container prüft vor dem Seafile-Start ob MariaDB erreichbar ist:

```yaml
initContainers:
  - name: wait-for-mariadb
    image: alpine
    command: ['sh', '-c', 'until nc -z mariadb 3306; do echo waiting; sleep 2; done']
```

**Option B — `startupProbe`**: Seafile bekommt eine großzügige Startup-Probe die mehrere Minuten wartet.

Option A ist expliziter und zuverlässiger.

---

## Secrets (Sealed Secrets)

Folgende Werte müssen als Secret im Cluster liegen — **nicht** im Klartext ins Repo:

| Key | Wert | Woher |
|---|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB Root-Passwort | Neu generieren |
| `MYSQL_PASSWORD` | Seafile DB-User-Passwort | Neu generieren |
| `SEAFILE_ADMIN_PASSWORD` | Seafile Admin-Passwort | Neu generieren |
| `SECRET_KEY` | Django Secret Key | `openssl rand -hex 32` |

Workflow wenn Sealed Secrets eingerichtet ist:
```bash
kubectl create secret generic seafile-secrets \
  --namespace seafile \
  --from-literal=MYSQL_ROOT_PASSWORD=<passwort> \
  --from-literal=MYSQL_PASSWORD=<passwort> \
  --from-literal=SEAFILE_ADMIN_PASSWORD=<passwort> \
  --from-literal=SECRET_KEY=$(openssl rand -hex 32) \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/seafile/sealed-secret.yaml

git add apps/seafile/sealed-secret.yaml
git commit -m "feat(seafile): add sealed secrets"
```

---

## Datenmigration (falls bestehende Seafile-Instanz vorhanden)

Seafile hat zwei voneinander unabhängige Datenbereiche:

```
Datei-Blobs  →  /shared/seafile/   → PVC seafile-data
Metadaten    →  MariaDB-Datenbank  → PVC mariadb-data
```

**Beide müssen konsistent migriert werden** — ein MariaDB-Dump ohne die passenden Blobs (oder umgekehrt) ergibt einen kaputten Zustand.

### Migrations-Strategie

```
1. Seafile auf alter Instanz in den Read-Only-Modus versetzen
   (verhindert Schreibzugriffe während der Migration)
2. MariaDB-Dump erstellen
3. Datei-Blobs rsyncen
4. MariaDB in k3s einspielen
5. Blobs in PVC kopieren
6. Seafile-Client auf einem Gerät testen
7. DNS / nginx umleiten
8. Alte Instanz abschalten
```

### Read-Only-Modus in Seafile aktivieren

```bash
# Seafile auf alter Instanz
seafile-admin maintenance --enable
```

Damit können Clients noch lesen/syncen, aber keine neuen Änderungen schreiben — kein Datenverlust während der Migration.

### MariaDB-Dump

```bash
# Auf alter Instanz (Docker):
docker exec seafile-db mysqldump -u root -p --all-databases > seafile-dump.sql
```

### Blobs rsyncen

Da Seafile sync-basiert ist, haben Clients alle Datei-Blobs lokal. Die Blobs auf dem Server sind aber die kanonische Quelle für Versionshistorie und Sharing-Links.

```bash
rsync -av /path/to/seafile/data/ <user>@<raspi-hostname>:/tmp/seafile-data/
```

---

## Neuinstallation (kein bestehendes Seafile)

Falls Seafile direkt in k3s neu aufgesetzt wird (kein Migration):
1. Manifeste anwenden
2. Seafile initialisiert sich selbst beim ersten Start
3. Admin-Account über die Web-UI einrichten
4. Seafile-Clients verbinden und sync einrichten

Das ist der einfachere Weg — und da Seafile noch nicht im docker-runtime liegt, möglicherweise der relevantere.

---

## Weiter: [Learning Path — Phase 5: GitOps mit Flux CD](./learning-path.md#phase-5--gitops-mit-flux-cd-woche-45)
