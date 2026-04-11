# Deploy Seafile

Prerequisite: [FreshRSS](./freshrss.md) completed. [SOPS + age](../platform/05-sops.md) must be set up before this step (secrets for DB password and Seafile SECRET_KEY).

Seafile is the second migration candidate and significantly more complex than FreshRSS: two pods, two volumes, service-to-service communication, and secrets. This makes it the ideal learning step before GitOps.

---

## Architecture

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
                    (local-path)          (local-path)
```

`seafile-mc` (the official image) contains Seafile, Seahub **and** memcached in a single container. This keeps the setup at two pods instead of four.

---

## New concepts compared to FreshRSS

| Concept | Why it matters here |
|---|---|
| Multiple Deployments in one Namespace | Seafile + MariaDB as separate workloads |
| Service-to-service communication | Seafile talks to MariaDB via CoreDNS |
| SOPS + age | DB password and Seafile `SECRET_KEY` must be encrypted in the repo |
| Startup dependency | MariaDB must be ready before Seafile starts |
| StatefulSet vs. Deployment | Databases want stable pod names → MariaDB as StatefulSet |

---

## Manifest overview (planned)

```
apps/seafile/
├── namespace.yaml
├── pvc-seafile.yaml          ← /shared/seafile (file blobs)
├── pvc-mariadb.yaml          ← /var/lib/mysql
├── statefulset-mariadb.yaml  ← MariaDB as StatefulSet
├── service-mariadb.yaml      ← ClusterIP, only reachable internally
├── deployment-seafile.yaml   ← seafile-mc container
├── service-seafile.yaml      ← ClusterIP → Ingress
├── ingress.yaml              ← domain routing
└── seafile-secrets.sops.yaml  ← DB password + SECRET_KEY (SOPS-encrypted)
```

---

## Why MariaDB as a StatefulSet?

Deployments create pods with random names (`mariadb-7d9f4b-xxxx`). On restart the pod gets a new name — no problem for stateless apps, but undesirable for databases: volume mounting can become unstable.

StatefulSets assign stable, predictable names (`mariadb-0`) and guarantee a defined startup order. Standard practice for databases in Kubernetes.

---

## Startup order: MariaDB before Seafile

Seafile fails to start if MariaDB is not yet ready. Two ways to solve this:

**Option A — `initContainer`** (recommended): A lightweight init container checks whether MariaDB is reachable before Seafile starts:

```yaml
initContainers:
  - name: wait-for-mariadb
    image: alpine
    command: ['sh', '-c', 'until nc -z mariadb 3306; do echo waiting; sleep 2; done']
```

**Option B — `startupProbe`**: Seafile gets a generous startup probe that waits several minutes.

Option A is more explicit and reliable.

---

## Secrets (SOPS)

The following values must exist as a secret in the cluster — **not** in plaintext in the repo:

| Key | Value | Source |
|---|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root password | Generate new |
| `MYSQL_PASSWORD` | Seafile DB user password | Generate new |
| `SEAFILE_ADMIN_PASSWORD` | Seafile admin password | Generate new |
| `SECRET_KEY` | Django secret key | `openssl rand -hex 32` |

Workflow with SOPS:
```bash
kubectl create secret generic seafile-secrets \
  --namespace seafile \
  --from-literal=MYSQL_ROOT_PASSWORD=<password> \
  --from-literal=MYSQL_PASSWORD=<password> \
  --from-literal=SEAFILE_ADMIN_PASSWORD=<password> \
  --from-literal=SECRET_KEY=$(openssl rand -hex 32) \
  --dry-run=client -o yaml > apps/seafile/seafile-secrets.sops.yaml

sops --encrypt --in-place apps/seafile/seafile-secrets.sops.yaml

git add apps/seafile/seafile-secrets.sops.yaml
git commit -m "feat(seafile): add SOPS-encrypted secrets"
```

---

## Data migration (if an existing Seafile instance exists)

Seafile has two independent data areas:

```
File blobs  →  /shared/seafile/   → PVC seafile-data
Metadata    →  MariaDB database   → PVC mariadb-data
```

**Both must be migrated consistently** — a MariaDB dump without the matching blobs (or vice versa) results in a broken state.

### Migration strategy

```
1. Put old Seafile instance into read-only mode
   (prevents writes during migration)
2. Create MariaDB dump
3. Rsync file blobs
4. Import MariaDB into k3s
5. Copy blobs into PVC
6. Test Seafile client on one device
7. Switch DNS / nginx
8. Shut down old instance
```

### Enable read-only mode in Seafile

```bash
# On the old instance
seafile-admin maintenance --enable
```

This allows clients to still read/sync but prevents new writes — no data loss during migration.

### MariaDB dump

```bash
# On the old instance (Docker):
docker exec seafile-db mysqldump -u root -p --all-databases > seafile-dump.sql
```

### Rsync blobs

Since Seafile is sync-based, clients have all file blobs locally. The blobs on the server are however the canonical source for version history and sharing links.

```bash
rsync -av /path/to/seafile/data/ <user>@<raspi-hostname>:/tmp/seafile-data/
```

---

## Fresh installation (no existing Seafile)

If Seafile is being set up directly in k3s (no migration):
1. Apply manifests
2. Seafile initialises itself on first start
3. Set up admin account via the web UI
4. Connect Seafile clients and configure sync

This is the simpler path — and since Seafile is not yet in the docker-runtime, possibly the more relevant one.

---

## Next: [Learning Path — Phase 5: GitOps with Flux CD](../learning-path.md#phase-5--gitops-with-flux-cd-week-45)
