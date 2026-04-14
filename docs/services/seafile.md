# Deploy Seafile

Prerequisite: [FreshRSS](./freshrss.md) completed. [SOPS + age](../platform/sops.md) must be set up before this step.

Seafile is significantly more complex than FreshRSS: three pods, two volumes, service-to-service communication, and secrets. It is set up directly in k3s (no migration from docker-runtime).

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

`seafile-mc` (the official image) contains Seafile and Seahub. **Redis** is required as cache provider since Seafile 13 and runs as a separate pod.

---

## New concepts compared to FreshRSS

| Concept | Why it matters here |
|---|---|
| Multiple Deployments in one Namespace | Seafile + MariaDB + Redis as separate workloads |
| Service-to-service communication | Seafile talks to MariaDB and Redis via CoreDNS |
| SOPS + age | DB password and JWT key must be encrypted in the repo |
| Startup dependency | MariaDB and Redis must be ready before Seafile starts |
| StatefulSet vs. Deployment | Databases want stable pod names → MariaDB as StatefulSet |

---

## Manifest overview

```
apps/seafile/
├── seafile.yaml                  ← Namespace, PVCs, StatefulSet (MariaDB), Deployments (Seafile, Redis), Services
├── seafile-secrets.sops.yaml     ← all Secrets SOPS-encrypted
├── seafile-ingress.yaml          ← .gitignore (hostname stays local)
└── seafile-ingress.yaml.example  ← Ingress template
```

---

## Why MariaDB as a StatefulSet?

Deployments create pods with random names (`mariadb-7d9f4b-xxxx`). On restart the pod gets a new name — no problem for stateless apps, but undesirable for databases: volume mounting can become unstable.

StatefulSets assign stable, predictable names (`mariadb-0`) and guarantee a defined startup order. Standard practice for databases in Kubernetes.

---

## Startup order

Seafile fails to start if MariaDB or Redis are not yet ready. Two init containers handle this:

```yaml
initContainers:
  - name: wait-for-mariadb
    image: alpine
    command: ['sh', '-c', 'until nc -z mariadb 3306; do echo waiting; sleep 2; done']
  - name: wait-for-redis
    image: alpine
    command: ['sh', '-c', 'until nc -z redis 6379; do echo waiting; sleep 2; done']
```

---

## Secrets (SOPS)

The following values must exist as a secret in the cluster — **not** in plaintext in the repo:

| Key | Value | Source |
|---|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root password | Generate new |
| `MYSQL_PASSWORD` | Seafile DB user password | Generate new |
| `SEAFILE_ADMIN_EMAIL` | Seafile admin email | Your email address |
| `SEAFILE_ADMIN_PASSWORD` | Seafile admin password | Generate new |
| `SEAFILE_SERVER_HOSTNAME` | Public hostname | e.g. `seafile.fritz.box` |
| `JWT_PRIVATE_KEY` | JWT signing key (min. 32 chars) | `openssl rand -base64 40` |

### Create and encrypt the secret

Always use `stringData` — values are human-readable after decryption, no base64 step needed (see [SOPS — base64 trap](../platform/sops.md#️-base64-trap--never-use-kubectl-create---dry-run-for-sops-secrets)).

```bash
# 1. Write plaintext manifest with stringData
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

# 2. Encrypt in place — picks up both recipients (YubiKey + cluster key) from .sops.yaml
sops --encrypt --in-place apps/seafile/seafile-secrets.sops.yaml
```

### Decrypt for inspection (local, YubiKey)

```bash
# YubiKey must be plugged in, pcscd must be running
sudo systemctl start pcscd

sops --decrypt apps/seafile/seafile-secrets.sops.yaml
# Values are immediately readable — no base64 -d needed
```

---

## Deployment via Flux

Seafile is deployed like all other services via Flux CD — no manual `kubectl apply` needed.

```bash
# 1. Create and encrypt the secret (see above)

# 2. Prepare ingress (gitignored — hostname stays local)
cp apps/seafile/seafile-ingress.yaml.example apps/seafile/seafile-ingress.yaml
vim apps/seafile/seafile-ingress.yaml  # fill in hostname
kubectl apply -f apps/seafile/seafile-ingress.yaml

# 3. Commit and push → Flux reconciles automatically
git add apps/seafile/seafile-secrets.sops.yaml
git commit -m "feat(seafile): add encrypted secrets"
git push

# 4. Optional: trigger reconciliation manually
flux reconcile kustomization apps --with-source
```

Watch pod status:
```bash
kubectl get pods -n seafile -w
```

Seafile initialises automatically on first start (DB setup, admin account). First startup takes ~1–2 minutes. The admin account is then accessible via the web UI.

---

## Notes

- **`SEAFILE_SERVER_PROTOCOL`** must be set in the Deployment (`http` or `https`) — without this variable the image generates `SERVICE_URL` and `FILE_SERVER_ROOT` incorrectly, and the browser receives a `localhost` URL for uploads (Network Error). The value is not sensitive and lives directly in the manifest.
- **`seafile-secrets.sops.yaml` must not contain k8s runtime metadata** (`uid`, `resourceVersion`, `creationTimestamp`) — these cause conflicts during Flux apply.
- **Readiness Probe**: The Seafile pod stays at `0/1` for up to ~2 minutes while Seahub starts. This is normal.
- **JWT_PRIVATE_KEY**: Not a derived value — an independently generated random string for JWT token signing.
