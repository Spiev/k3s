# Teslamate Migration: Docker → k3s

Stack: **Teslamate** (Elixir app) + **PostgreSQL 18** + **Grafana** (Teslamate-custom image)

Quelle: `raspberrypi` → `~/docker/teslamate/`

---

## Stack-Übersicht

| Container | Image | Port |
|---|---|---|
| teslamate | `teslamate/teslamate:3.0.0` | 4000 |
| teslamate-db | `postgres:18-alpine` | 5432 (intern) |
| teslamate-grafana | `teslamate/grafana:3.0.0` | 3000 |

Daten:
- Postgres-DB: ~220 MB (Fahrthistorie)
- Grafana: ~3 MB (Dashboards + Settings)
- Import-Ordner: ephemeral (Tesla-Importdateien)

---

## Vorbereitung

### 1. Aktuellen DB-Dump erstellen

Auf `raspberrypi` — frischen Dump erstellen (nicht den nächtlichen nehmen, um Datenverlust zu minimieren):

```bash
ssh raspberrypi
TIMESTAMP=$(date +%Y-%m-%d_%H_%M_%S)
docker exec teslamate-db pg_dump -U teslamate teslamate | gzip \
  > ~/docker/teslamate/backup/teslamate_${TIMESTAMP}.sql.gz
echo "Dump: ~/docker/teslamate/backup/teslamate_${TIMESTAMP}.sql.gz"
```

### 2. Grafana-Daten sichern

```bash
ssh raspberrypi "tar czf /tmp/teslamate-grafana.tar.gz -C ~/docker/teslamate/grafana ."
```

---

## Deployment auf k3s

### 1. Secret anpassen und verschlüsseln (schon erledigt, ist redundant)

`GRAFANA_ROOT_URL` in `apps/teslamate/teslamate-secrets.sops.yaml` eintragen (muss mit der tatsächlichen Grafana-Domain übereinstimmen), dann verschlüsseln:

```bash
# YubiKey einstecken, pcscd starten
sudo systemctl start pcscd

# GRAFANA_ROOT_URL in der Datei anpassen, dann:
sops --encrypt --in-place apps/teslamate/teslamate-secrets.sops.yaml
```

### 2. Manifeste deployen

```bash
# Vom Laptop — kubectl zeigt auf den k3s-Cluster
kubectl apply -f apps/teslamate/teslamate.yaml
kubectl apply -f apps/teslamate/teslamate-secrets.sops.yaml

# Warten bis Postgres bereit ist
kubectl wait --for=condition=Ready pod -n teslamate -l app=teslamate-db --timeout=60s
```

### 3. DB-Dump importieren

```bash
# Dump vom raspberrypi auf den Laptop holen
scp raspberrypi:~/docker/teslamate/backup/teslamate_<TIMESTAMP>.sql.gz /tmp/

# In den laufenden Postgres-Pod importieren
DB_POD=$(kubectl get pod -n teslamate -l app=teslamate-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/teslamate_<TIMESTAMP>.sql.gz \
  | kubectl exec -i -n teslamate "$DB_POD" -- psql -U teslamate teslamate

# Prüfen
kubectl exec -n teslamate "$DB_POD" -- psql -U teslamate -c 'SELECT count(*) FROM drives;' teslamate
# Sollte ~385 ergeben (oder mehr, je nach aktuellen Daten)
```

### 4. Grafana-Daten übertragen

```bash
# Grafana-Deployment stoppen (PVC darf nicht von laufendem Pod gehalten werden)
kubectl scale deployment teslamate-grafana -n teslamate --replicas=0
kubectl wait --for=delete pod -n teslamate -l app=teslamate-grafana --timeout=30s

# Grafana-Daten kopieren (via temporärem Pod)
kubectl run grafana-restore --image=alpine:3.23 --restart=Never \
  -n teslamate \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"teslamate-grafana"}}],"containers":[{"name":"grafana-restore","image":"alpine:3.23","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}'

kubectl wait --for=condition=Ready pod -n teslamate grafana-restore --timeout=30s

# Tar-Archiv in Pod kopieren und entpacken
scp raspberrypi:/tmp/teslamate-grafana.tar.gz /tmp/
kubectl cp /tmp/teslamate-grafana.tar.gz teslamate/grafana-restore:/tmp/
kubectl exec -n teslamate grafana-restore -- tar xzf /tmp/teslamate-grafana.tar.gz -C /data

# Restore-Pod entfernen, Deployment wieder starten
kubectl delete pod -n teslamate grafana-restore
kubectl scale deployment teslamate-grafana -n teslamate --replicas=1
```

---

## Ingress konfigurieren

```bash
# Ingress-Dateien aus den Beispielen anlegen und Domains eintragen
cp apps/teslamate/teslamate-ingress.yaml.example apps/teslamate/teslamate-ingress.yaml
cp apps/teslamate/grafana-ingress.yaml.example apps/teslamate/grafana-ingress.yaml

# Domains in beiden Dateien anpassen, dann anwenden
kubectl apply -f apps/teslamate/teslamate-ingress.yaml
kubectl apply -f apps/teslamate/grafana-ingress.yaml
```

> `teslamate-ingress.yaml` und `grafana-ingress.yaml` sind in `.gitignore` — nicht committen.

---

## Verifizieren

```bash
# Pods laufen?
kubectl get pods -n teslamate

# Teslamate UI erreichbar?
curl -s -o /dev/null -w "%{http_code}" http://<teslamate-domain>/

# Grafana erreichbar?
curl -s -o /dev/null -w "%{http_code}" http://<grafana-domain>/api/health

# MQTT-Verbindung prüfen (Teslamate-Logs)
kubectl logs -n teslamate -l app=teslamate | grep -i mqtt
```

In der Teslamate-UI: **Settings → Car** — Status sollte "Online" oder "Asleep" zeigen.

In Grafana: Dashboards → **Overview** — Fahrten aus dem Import sichtbar?

---

## Umschalten: nginx auf k3s zeigen

Auf `raspberrypi` in der nginx-Konfiguration den `proxy_pass` für Teslamate und Grafana auf den k3s-Node umstellen:

```nginx
# vorher: proxy_pass http://localhost:4000;
proxy_pass http://<k3s-node-ip>;   # Traefik übernimmt das Routing via Host-Header
```

Nach nginx reload:

```bash
sudo nginx -t && sudo nginx -s reload
```

---

## Docker-Container stoppen

Erst stoppen wenn alles auf k3s verifiziert ist:

```bash
ssh raspberrypi "cd ~/docker/teslamate && docker compose stop"
# Noch nicht: docker compose down (Daten bleiben als Fallback)
```

Nach einigen Tagen ohne Probleme:

```bash
ssh raspberrypi "cd ~/docker/teslamate && docker compose down"
# Optional: rm -rf ~/docker/teslamate/postgres ~/docker/teslamate/grafana
```

---

## Backup-Integration

Das bestehende Backup-Script auf `raspberrypi` (`~/docker/teslamate/backup/`) läuft weiterhin solange die Docker-Container aktiv sind. Nach der Migration → Backup über das neue `scripts/backup.sh` im k3s-Repo einrichten (separater Schritt, nach Teslamate-Migration).
