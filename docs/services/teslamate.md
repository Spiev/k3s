# Teslamate

Stack: **Teslamate** (Elixir app) + **PostgreSQL 18** + **Grafana** (Teslamate-custom image)

---

## Stack overview

| Container | Image | Port |
|---|---|---|
| teslamate | `teslamate/teslamate:3.0.0` | 4000 |
| teslamate-db | `postgres:18-alpine` | 5432 (internal) |
| teslamate-grafana | `teslamate/grafana:3.0.0` | 3000 |

---

## Manifest overview

```
apps/teslamate/
├── teslamate.yaml                    ← Namespace, PVCs, Deployments, Services
├── teslamate-secrets.sops.yaml       ← SOPS-encrypted secrets
├── teslamate-ingress.yaml            ← .gitignore (Teslamate UI domain)
├── teslamate-ingress.yaml.example    ← template
├── grafana-ingress.yaml              ← .gitignore (Grafana domain)
└── grafana-ingress.yaml.example      ← template
```

---

## Secrets

`GRAFANA_ROOT_URL` must match the actual Grafana domain configured in the ingress.

```bash
# Insert YubiKey, start pcscd
sudo systemctl start pcscd

sops --decrypt apps/teslamate/teslamate-secrets.sops.yaml
# Edit, then re-encrypt:
sops --encrypt --in-place apps/teslamate/teslamate-secrets.sops.yaml
```

---

## Ingress setup

```bash
cp apps/teslamate/teslamate-ingress.yaml.example apps/teslamate/teslamate-ingress.yaml
cp apps/teslamate/grafana-ingress.yaml.example apps/teslamate/grafana-ingress.yaml
# Fill in domains, then:
kubectl apply -f apps/teslamate/teslamate-ingress.yaml
kubectl apply -f apps/teslamate/grafana-ingress.yaml
```

> Both ingress files are in `.gitignore` — do not commit.

---

## Verify

```bash
kubectl get pods -n teslamate

# Teslamate UI reachable?
curl -s -o /dev/null -w "%{http_code}" http://<teslamate-domain>/

# Grafana reachable?
curl -s -o /dev/null -w "%{http_code}" http://<grafana-domain>/api/health

# MQTT connection
kubectl logs -n teslamate -l app=teslamate | grep -i mqtt
```

In the Teslamate UI: **Settings → Car** — status should show "Online" or "Asleep".

---

## Backup

Backups are handled by `scripts/backup.sh` on the k3s node — daily pg_dump → Restic → Hetzner S3. See [Backup & Restore](../operations/backup-restore.md).
