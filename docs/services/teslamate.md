# Teslamate Migration: Docker → k3s

Stack: **Teslamate** (Elixir app) + **PostgreSQL 18** + **Grafana** (Teslamate-custom image)

Source: `raspberrypi` → `~/docker/teslamate/`

---

## Stack Overview

| Container | Image | Port |
|---|---|---|
| teslamate | `teslamate/teslamate:3.0.0` | 4000 |
| teslamate-db | `postgres:18-alpine` | 5432 (internal) |
| teslamate-grafana | `teslamate/grafana:3.0.0` | 3000 |

Data:
- Postgres DB: ~220 MB (drive history)
- Grafana: ~3 MB (dashboards + settings)
- Import folder: ephemeral (Tesla import files)

---

## Preparation

### 1. Create a fresh DB dump

On `raspberrypi` — create a fresh dump (don't use the nightly one, to minimise data loss):

```bash
ssh raspberrypi
TIMESTAMP=$(date +%Y-%m-%d_%H_%M_%S)
docker exec teslamate-db pg_dump -U teslamate teslamate | gzip \
  > ~/docker/teslamate/backup/teslamate_${TIMESTAMP}.sql.gz
echo "Dump: ~/docker/teslamate/backup/teslamate_${TIMESTAMP}.sql.gz"
```

### 2. Back up Grafana data

```bash
ssh raspberrypi "tar czf /tmp/teslamate-grafana.tar.gz -C ~/docker/teslamate/grafana ."
```

---

## Deployment on k3s

### 1. Adjust and encrypt the Secret (already done, kept for reference)

Set `GRAFANA_ROOT_URL` in `apps/teslamate/teslamate-secrets.sops.yaml` (must match the actual Grafana domain), then encrypt:

```bash
# Insert YubiKey, start pcscd
sudo systemctl start pcscd

# Adjust GRAFANA_ROOT_URL in the file, then:
sops --encrypt --in-place apps/teslamate/teslamate-secrets.sops.yaml
```

### 2. Deploy manifests

```bash
# From laptop — kubectl points to the k3s cluster
kubectl apply -f apps/teslamate/teslamate.yaml
kubectl apply -f apps/teslamate/teslamate-secrets.sops.yaml

# Wait until Postgres is ready
kubectl wait --for=condition=Ready pod -n teslamate -l app=teslamate-db --timeout=60s
```

### 3. Import the DB dump

```bash
# Copy dump from raspberrypi to laptop
scp raspberrypi:~/docker/teslamate/backup/teslamate_<TIMESTAMP>.sql.gz /tmp/

# Import into the running Postgres pod
DB_POD=$(kubectl get pod -n teslamate -l app=teslamate-db -o jsonpath='{.items[0].metadata.name}')
zcat /tmp/teslamate_<TIMESTAMP>.sql.gz \
  | kubectl exec -i -n teslamate "$DB_POD" -- psql -U teslamate teslamate

# Verify
kubectl exec -n teslamate "$DB_POD" -- psql -U teslamate -c 'SELECT count(*) FROM drives;' teslamate
# Should return ~385 (or more, depending on current data)
```

### 4. Transfer Grafana data

```bash
# Scale down Grafana (PVC must not be held by a running pod)
kubectl scale deployment teslamate-grafana -n teslamate --replicas=0
kubectl wait --for=delete pod -n teslamate -l app=teslamate-grafana --timeout=30s

# Copy Grafana data via a temporary pod
kubectl run grafana-restore --image=alpine:3.23 --restart=Never \
  -n teslamate \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"teslamate-grafana"}}],"containers":[{"name":"grafana-restore","image":"alpine:3.23","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}'

kubectl wait --for=condition=Ready pod -n teslamate grafana-restore --timeout=30s

# Copy tar archive into pod and extract
scp raspberrypi:/tmp/teslamate-grafana.tar.gz /tmp/
kubectl cp /tmp/teslamate-grafana.tar.gz teslamate/grafana-restore:/tmp/
kubectl exec -n teslamate grafana-restore -- tar xzf /tmp/teslamate-grafana.tar.gz -C /data

# Remove restore pod and scale Grafana back up
kubectl delete pod -n teslamate grafana-restore
kubectl scale deployment teslamate-grafana -n teslamate --replicas=1
```

---

## Configure Ingress

```bash
# Create ingress files from examples and set domains
cp apps/teslamate/teslamate-ingress.yaml.example apps/teslamate/teslamate-ingress.yaml
cp apps/teslamate/grafana-ingress.yaml.example apps/teslamate/grafana-ingress.yaml

# Adjust domains in both files, then apply
kubectl apply -f apps/teslamate/teslamate-ingress.yaml
kubectl apply -f apps/teslamate/grafana-ingress.yaml
```

> `teslamate-ingress.yaml` and `grafana-ingress.yaml` are in `.gitignore` — do not commit.

---

## Verify

```bash
# Pods running?
kubectl get pods -n teslamate

# Teslamate UI reachable?
curl -s -o /dev/null -w "%{http_code}" http://<teslamate-domain>/

# Grafana reachable?
curl -s -o /dev/null -w "%{http_code}" http://<grafana-domain>/api/health

# Check MQTT connection (Teslamate logs)
kubectl logs -n teslamate -l app=teslamate | grep -i mqtt
```

In the Teslamate UI: **Settings → Car** — status should show "Online" or "Asleep".

In Grafana: Dashboards → **Overview** — are the imported drives visible?

---

## Switch: point nginx to k3s

On `raspberrypi`, update the nginx configuration to point `proxy_pass` for Teslamate and Grafana to the k3s node:

```nginx
# before: proxy_pass http://localhost:4000;
proxy_pass http://<k3s-node-ip>;   # Traefik handles routing via Host header
```

After nginx reload:

```bash
sudo nginx -t && sudo nginx -s reload
```

---

## Stop Docker containers

Only stop once everything is verified on k3s:

```bash
ssh raspberrypi "cd ~/docker/teslamate && docker compose stop"
# Not yet: docker compose down (data remains as fallback)
```

After a few days without issues:

```bash
ssh raspberrypi "cd ~/docker/teslamate && docker compose down"
# Optional: rm -rf ~/docker/teslamate/postgres ~/docker/teslamate/grafana
```

---

## Backup integration

Once migrated, backups are handled by `scripts/backup.sh` on the k3s node (Restic → Hetzner S3). The old Docker backup script on `raspberrypi` has been updated to remove the Teslamate section.
