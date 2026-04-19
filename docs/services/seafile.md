# Seafile

Prerequisite: [SOPS + age](../platform/sops.md) must be set up.

Seafile is a self-hosted file sync and share platform. The stack consists of three pods: Seafile (`seafile-mc`), MariaDB, and Redis.

---

## Architecture

```
[Ingress/Traefik]
      │  Host: seafile.example.com
      ▼
[Service: seafile]  →  [Pod: seafile-mc]
                              │  mariadb.seafile.svc.cluster.local:3306
                              │  redis.seafile.svc.cluster.local:6379
                              ▼
                    [Service: mariadb]  →  [Pod: mariadb]
                    [Service: redis]    →  [Pod: redis]
                                                │
                              ┌─────────────────┘
                              ▼
                    [PVC: mariadb-data]   [PVC: seafile-data]
                    (local-path)          (local-path)
```

`seafile-mc` contains both Seafile and Seahub. **Redis** is required as cache provider since Seafile 13.

---

## Manifest overview

```
apps/seafile/
├── seafile.yaml                  ← Namespace, PVCs, StatefulSet (MariaDB), Deployments (Seafile, Redis), Services
├── seafile-secrets.sops.yaml     ← all Secrets SOPS-encrypted
├── seafile-ingress.yaml          ← .gitignore (hostname stays local)
└── seafile-ingress.yaml.example  ← Ingress template
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
| `SEAFILE_SERVER_HOSTNAME` | Public hostname (e.g. `seafile.fritz.box`) |
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

## Notes

- **`SEAFILE_SERVER_PROTOCOL`** must be set in the Deployment (`http` or `https`) — without it the image generates incorrect `SERVICE_URL` and `FILE_SERVER_ROOT` values, causing upload errors in the browser.
- **`seafile-secrets.sops.yaml`** must not contain k8s runtime metadata (`uid`, `resourceVersion`, `creationTimestamp`) — these cause conflicts during Flux apply.
- **Readiness Probe**: The pod stays at `0/1` for up to ~2 minutes while Seahub starts. This is normal.
