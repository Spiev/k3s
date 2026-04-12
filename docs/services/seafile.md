# Deploy Seafile

Prerequisite: [FreshRSS](./freshrss.md) completed. [SOPS + age](../platform/sops.md) must be set up before this step (secrets for DB password and Seafile SECRET_KEY).

Seafile is significantly more complex than FreshRSS: two pods, two volumes, service-to-service communication, and secrets. It is set up directly in k3s (no migration from docker-runtime).

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

## Manifest overview

```
apps/seafile/
├── seafile.yaml                  ← Namespace, PVCs, StatefulSet (MariaDB), Deployment (Seafile), Services
├── seafile-secrets.sops.yaml     ← alle Secrets SOPS-verschlüsselt (nicht im Repo)
├── seafile-ingress.yaml          ← .gitignore (Hostname bleibt lokal)
└── seafile-ingress.yaml.example  ← Template für den Ingress
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
| `SEAFILE_ADMIN_EMAIL` | Seafile admin email | Your email address |
| `SEAFILE_ADMIN_PASSWORD` | Seafile admin password | Generate new |
| `SEAFILE_SERVER_HOSTNAME` | Public hostname | e.g. `seafile.fritz.box` |
| `JWT_PRIVATE_KEY` | JWT signing key (min. 32 chars) | `openssl rand -base64 40` |

Create and encrypt using the [SOPS workflow](../platform/sops.md#step-6--creating-an-encrypted-secret) with secret name `seafile-secrets` in namespace `seafile`:

```bash
kubectl create secret generic seafile-secrets \
  --namespace seafile \
  --from-literal=MYSQL_ROOT_PASSWORD=<passwort> \
  --from-literal=MYSQL_PASSWORD=<passwort> \
  --from-literal=SEAFILE_ADMIN_EMAIL=<deine-email> \
  --from-literal=SEAFILE_ADMIN_PASSWORD=<passwort> \
  --from-literal=SEAFILE_SERVER_HOSTNAME=<hostname> \
  --from-literal=JWT_PRIVATE_KEY=$(openssl rand -base64 40) \
  --dry-run=client -o yaml > apps/seafile/seafile-secrets.sops.yaml
sops --encrypt --in-place apps/seafile/seafile-secrets.sops.yaml
```

---

---

## Fresh installation (no existing Seafile)

Since Seafile was never in docker-runtime, this is the relevant path.

```bash
# 1. SOPS Secret erstellen (siehe Abschnitt Secrets oben)

# 2. Namespace anlegen
kubectl create namespace seafile --save-config

# 3. Secret deployen
kubectl apply -f apps/seafile/seafile-secrets.sops.yaml

# 4. Manifeste deployen (direkt aus dem Repo, kein Anpassen nötig)
kubectl apply -f apps/seafile/seafile.yaml

# 5. Ingress erstellen (gitignored — Hostname bleibt lokal)
cp apps/seafile/seafile-ingress.yaml.example apps/seafile/seafile-ingress.yaml
vim apps/seafile/seafile-ingress.yaml  # Hostname eintragen
kubectl apply -f apps/seafile/seafile-ingress.yaml
```

Monitor status:
```bash
kubectl get pods -n seafile -w
# Warten bis beide Pods (mariadb-0 und seafile) Running sind

kubectl get svc -n seafile
```

Seafile initialisiert sich beim ersten Start automatisch. Admin-Account ist über die Web UI zugänglich.

---

## Next: [Learning Path — Phase 5: GitOps with Flux CD](../learning-path.md#phase-5--gitops-with-flux-cd)
