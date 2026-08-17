# Seafile

Prerequisite: [SOPS + age](../platform/sops.md) must be set up.

Seafile is a self-hosted file sync and share platform. The stack consists of four pods: Seafile (`seafile-mc`), MariaDB, Redis, and Collabora Online (browser-based office document editing).

---

## Architecture

```
                       [Ingress/Traefik] — Host: seafile.example.com
                              │
              ┌───────────────┴────────────────────┐
              │ / (default)                         │ /browser, /cool, /hosting
              ▼                                      ▼
[Service: seafile]  →  [Pod: seafile-mc]     [Service: collabora] → [Pod: collabora]
                              │  mariadb.seafile.svc.cluster.local:3306
                              │  redis.seafile.svc.cluster.local:6379
                              │  WOPI discovery: https://<public-hostname>/hosting/discovery
                              │  (via Ingress, not the internal collabora Service — see below)
                              ▼
                    [Service: mariadb]  →  [Pod: mariadb]
                    [Service: redis]    →  [Pod: redis]
                                                │
                              ┌─────────────────┘
                              ▼
                    [PVC: mariadb-data]   [PVC: seafile-data]
                    (local-path)          (local-path)
```

`seafile-mc` contains both Seafile and Seahub. **Redis** is required as cache provider since Seafile 13. **Collabora** is stateless (no PVC) and shares the Seafile hostname via path-based Ingress routing — see [Collabora / Online-Office-Editing](#collabora--online-office-editing) below.

---

## Manifest overview

```
apps/seafile/
├── seafile.yaml                  ← Namespace, PVCs, StatefulSet (MariaDB), Deployments (Seafile, Redis, Collabora), Services
├── seafile-secrets.sops.yaml     ← all Secrets SOPS-encrypted
├── seafile-ingress.yaml          ← .gitignore (hostname stays local)
└── seafile-ingress.yaml.example  ← Ingress template (Seafile + Collabora paths)
```

**MariaDB runs as a StatefulSet** to get a stable, predictable pod name (`mariadb-0`) — standard practice for databases in Kubernetes.

**Startup order** is enforced via init containers: Seafile waits for MariaDB and Redis to be ready before starting.

---

## Secrets (SOPS)

| Key | Value |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root password |
| `MYSQL_PASSWORD` | Seafile DB user password |
| `SEAFILE_ADMIN_EMAIL` | Seafile admin email |
| `SEAFILE_ADMIN_PASSWORD` | Seafile admin password |
| `SEAFILE_SERVER_HOSTNAME` | Public hostname (e.g. `seafile.fritz.box`) — also used by Collabora (`net.server_hostname`, WOPI host allowlist), see below |
| `JWT_PRIVATE_KEY` | JWT signing key — `openssl rand -base64 40` |

Always use `stringData` — values are readable after decryption, no base64 step needed (see [SOPS — base64 trap](../platform/sops.md#️-base64-trap--never-use-kubectl-create---dry-run-for-sops-secrets)).

```bash
cat > apps/seafile/seafile-secrets.sops.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: seafile-secrets
  namespace: seafile
  labels:
    app: seafile
    managed-by: flux
stringData:
  MYSQL_ROOT_PASSWORD: "<password>"
  MYSQL_PASSWORD: "<password>"
  SEAFILE_ADMIN_EMAIL: "<your-email>"
  SEAFILE_ADMIN_PASSWORD: "<password>"
  SEAFILE_SERVER_HOSTNAME: "<hostname>"
  JWT_PRIVATE_KEY: "$(openssl rand -base64 40)"
EOF

sops --encrypt --in-place apps/seafile/seafile-secrets.sops.yaml
```

---

## Deploy

```bash
# 1. Prepare ingress
cp apps/seafile/seafile-ingress.yaml.example apps/seafile/seafile-ingress.yaml
# Fill in hostname, then:
kubectl apply -f apps/seafile/seafile-ingress.yaml

# 2. Commit and push → Flux reconciles automatically
git add apps/seafile/seafile-secrets.sops.yaml
git commit -m "feat(seafile): add encrypted secrets"
git push

# 3. Optional: trigger reconciliation manually
flux reconcile kustomization apps --with-source
```

Watch pod status:
```bash
kubectl get pods -n seafile -w
```

First startup takes ~1–2 minutes while Seahub initialises. The admin account is accessible via the web UI afterwards.

---

## Collabora / Online-Office-Editing

Architecture decision: [Collabora Online instead of OnlyOffice](../decisions/online-office.md). Documents (`.odt`, `.docx`, `.xlsx`, `.pptx`, …) open and save directly in the browser via the WOPI protocol — no download/upload round-trip.

**No new hostname, no new certificate.** Collabora is reachable under the *same* domain as Seafile — Collabora natively serves its own routes under the top-level paths `/browser`, `/cool`, `/hosting`, so Traefik just needs three extra path rules pointing at the `collabora` Service (see `seafile-ingress.yaml.example`). The existing nginx reverse-proxy layer (in the companion `docker-runtime` repo) already forwards the whole domain to Traefik regardless of path and already sets the WebSocket upgrade headers Collabora needs — no change required there.

- **`OFFICE_WEB_APP_BASE_URL` must be the public URL** (`https://<SEAFILE_SERVER_HOSTNAME>/hosting/discovery`), *not* the internal `collabora.seafile.svc` service name — despite the official Seafile manual's same-host example using the internal name. Seahub does not use the host embedded in Collabora's own discovery-XML response (`urlsrc`) to build the editor iframe URL; it reuses the host from `OFFICE_WEB_APP_BASE_URL` directly. Pointing it internally makes the *browser* try to resolve `collabora:9980` itself, which fails outside the cluster. This is reachable from the Seafile pod too in this setup because local DNS (Pi-hole) resolves the public hostname to a LAN IP — no hairpin-NAT issue — but confirm that holds for your own DNS setup before relying on it.
- Collabora's own `--o:net.server_hostname` (`extra_params`) still needs to be the same public hostname, so the discovery XML itself is internally consistent — some other WOPI-host implementations (unlike Seahub, per the above) do read the host from there.
- No shared JWT secret is needed between Seafile and Collabora. Seahub issues a short-lived WOPI access token per edit session (`WOPI_ACCESS_TOKEN_EXPIRATION`, 30 min); Collabora's own auth is the WOPI host allowlist (`storage.wopi.host`, set via `extra_params` to `SEAFILE_SERVER_HOSTNAME`). The existing `JWT_PRIVATE_KEY` secret is Seafile's *internal* Seahub↔fileserver auth and is unrelated to Collabora.
- Collabora is **stateless** — no PVC, no database. `resources.limits` are set (2 GiB / 2 CPU) so a runaway rendering session can't starve the node; see the [ADR](../decisions/online-office.md) for the RAM budget this was sized against.
- Placement stays flexible — no `nodeAffinity`. If a third node joins later, it's a one-line `nodeSelector` change.
- Admin console is disabled (`--o:admin_console.enable=false`) — not needed for 1–3 home users, avoids an extra login surface.

```bash
kubectl logs -n seafile deploy/collabora        # watch for "Unauthorized WOPI host" during setup
kubectl exec -n seafile deploy/seafile -- curl -s -o /dev/null -w '%{http_code}\n' https://<hostname>/hosting/discovery
```

---

## Notes

- **`SEAFILE_SERVER_PROTOCOL`** must be set in the Deployment (`http` or `https`) — without it the image generates incorrect `SERVICE_URL` and `FILE_SERVER_ROOT` values, causing upload errors in the browser.
- **`seafile-secrets.sops.yaml`** must not contain k8s runtime metadata (`uid`, `resourceVersion`, `creationTimestamp`) — these cause conflicts during Flux apply.
- **Readiness Probe**: The pod stays at `0/1` for up to ~2 minutes while Seahub starts. This is normal.
- **Collabora `OFFICE_WEB_APP_BASE_URL`**: must be the public hostname, not the internal service name — see above. Symptom if wrong: browser error "server not found" / "kann sich nicht mit `collabora:9980` verbinden" when opening a document.
- **nginx idle timeout**: the `docker-runtime` reverse proxy sets `proxy_read_timeout 300s` on the Seafile vhost. A long-idle Collabora editing session could hit this — if WebSocket drops are observed, add a dedicated `location /cool` block with a longer timeout there (separate repo).
