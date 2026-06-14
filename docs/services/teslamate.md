# Teslamate

Stack: **Teslamate** (Elixir app) + **PostgreSQL 18** + **Grafana** (Teslamate-custom image)

---

## Stack overview

| Container | Image | Port |
|---|---|---|
| teslamate | `teslamate/teslamate:4.0.0` | 4000 |
| teslamate-db | `postgres:18-alpine` | 5432 (internal) |
| teslamate-grafana | `teslamate/grafana:4.0.0` | 3000 |

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

## Tesla Fleet API authentication

Since TeslaMate v4 the discontinued Tesla **Owner API** no longer works. This setup uses
the **direct Fleet API** — deliberately **without** any external proxy (MyTeslaMate /
Teslemetry) and **without** a local vehicle-command proxy (read-only data collection only).

### One-time setup (already done, for reference)

- A Tesla **Developer App** provides `client_id` + `client_secret`.
- Partner registration requires a public EC key served at
  `https://<subdomain>/.well-known/appspecific/com.tesla.3p.public-key.pem`.
  This is hosted as a **static file on the nginx edge in `../docker-runtime`** (not in
  k3s/Traefik, since internet ingress runs through docker-runtime). The public key is not
  secret; the private key never leaves the workstation.
- The manifest sets these env vars (see `teslamate.yaml`):
  `TESLA_API_HOST=https://fleet-api.prd.eu.vn.cloud.tesla.com`,
  `TESLA_AUTH_HOST=https://auth.tesla.com`, `TESLA_AUTH_PATH=/oauth2/v3`,
  `TESLA_AUTH_CLIENT_ID` (via SOPS).
- Token **refresh needs only `client_id`** — the `client_secret` is **not** stored in k3s;
  it is needed solely for the manual token exchange below.

### Token login (and re-auth when it breaks)

TeslaMate stores the user tokens in its DB (encrypted with `ENCRYPTION_KEY`). To obtain them:

1. **Authorize** — open in a browser (replace `<CLIENT_ID>`):
   ```
   https://auth.tesla.com/oauth2/v3/authorize?response_type=code&client_id=<CLIENT_ID>&redirect_uri=https://<subdomain>/auth/callback&scope=openid%20offline_access%20vehicle_device_data%20vehicle_location&state=db123
   ```
   Tesla redirects back to the nginx edge, which returns **404 — this is expected** (no
   callback handler). The authorization `code` is in the address bar. Copy **only** the
   value between `code=` and the next `&` (do *not* include `&issuer=…`).

2. **Exchange** the code for tokens (code is single-use, expires in ~minutes):
   ```bash
   curl -s -X POST https://auth.tesla.com/oauth2/v3/token \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     -d grant_type=authorization_code \
     -d client_id=<CLIENT_ID> \
     -d 'client_secret=<CLIENT_SECRET>' \
     -d code=<CODE> \
     -d 'audience=https://fleet-api.prd.eu.vn.cloud.tesla.com' \
     -d 'redirect_uri=https://<subdomain>/auth/callback' | tee /tmp/tesla_tokens.json | jq .
   ```
   > Quote `client_secret` — it may contain shell-special characters (e.g. `^` in fish).

3. **Verify scopes** — the `scp` field in the JSON response is empty; the real scopes live
   only in the access-token JWT. Decode and confirm `vehicle_device_data` + `vehicle_location`:
   ```bash
   jq -r .access_token /tmp/tesla_tokens.json | cut -d. -f2 | tr '_-' '/+' \
     | awk '{l=length%4; if(l>0) for(i=0;i<4-l;i++) $0=$0"="; print}' \
     | base64 -d 2>/dev/null | jq .scp
   ```

4. **Enter both** `access_token` and `refresh_token` into the TeslaMate UI sign-in form
   (both fields are mandatory).

### Troubleshooting: `403 Unauthorized missing scopes`

Symptom — auth works but every API call 403s:
```
GET .../api/1/vehicles/<id> -> 403   "error" => "Unauthorized missing scopes"
```
Cause: the token lacks `vehicle_device_data`/`vehicle_location`. Tesla caches a previous
consent with narrower scopes and **skips the consent screen** on re-auth, re-issuing a
scope-poor token. Fix:

1. **Revoke** the app's access in the **Tesla mobile app** (Profile → Security →
   third-party apps). The website account page does not expose this reliably.
2. Re-run the authorize + exchange above — the fresh token now carries the scopes.

A healthy state in the logs (`kubectl logs -n teslamate deploy/teslamate`):
```
POST https://auth.tesla.com/oauth2/v3/token -> 200
Scheduling token refresh in 6 h
car_id=1 [info] Start / :offline      # car asleep — not an error
```

> **Streaming API:** disable it in TeslaMate *Settings*. The legacy streaming endpoint does
> not authenticate with Fleet API tokens, and Fleet Telemetry would require the
> vehicle-command proxy (not deployed). TeslaMate falls back to polling.

> **No backfill:** data from the outage window is lost — TeslaMate only records live polling,
> the Fleet API has no historical drive/charge endpoint. Mileage/SoC simply resume at the
> current value.

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
