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
├── seafile-secrets.sops.yaml     ← alle Secrets SOPS-verschlüsselt
├── seafile-ingress.yaml          ← .gitignore (Hostname bleibt lokal)
└── seafile-ingress.yaml.example  ← Template für den Ingress
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

### Secret erstellen und verschlüsseln

```bash
# 1. Secret direkt im Cluster anlegen
kubectl create secret generic seafile-secrets \
  --namespace seafile \
  --from-literal=MYSQL_ROOT_PASSWORD=<passwort> \
  --from-literal=MYSQL_PASSWORD=<passwort> \
  --from-literal=SEAFILE_ADMIN_EMAIL=<deine-email> \
  --from-literal=SEAFILE_ADMIN_PASSWORD=<passwort> \
  --from-literal=SEAFILE_SERVER_HOSTNAME=<hostname> \
  --from-literal=JWT_PRIVATE_KEY=$(openssl rand -base64 40)

# 2. Exportieren, bereinigen und verschlüsseln
kubectl get secret seafile-secrets -n seafile -o yaml \
  | grep -v 'creationTimestamp\|resourceVersion\|uid\|managedFields\|annotations' \
  > apps/seafile/seafile-secrets.sops.yaml

sops --encrypt --in-place apps/seafile/seafile-secrets.sops.yaml
```

SOPS verschlüsselt automatisch für beide Empfänger (YubiKey + Cluster-Key) gemäß `.sops.yaml`.

### Secret entschlüsseln (lokal lesen)

Voraussetzungen:
- YubiKey eingesteckt
- `pcscd` läuft: `sudo systemctl start pcscd`
- age-plugin-yubikey Identity hinterlegt: `age-plugin-yubikey --identity >> ~/.config/sops/age/keys.txt`

```bash
sops --decrypt apps/seafile/seafile-secrets.sops.yaml
```

> **Hinweis**: Die Werte im `data`-Feld sind base64-kodiert (k8s-Standard). Einzelnen Wert dekodieren:
> ```bash
> sops --decrypt --extract '["data"]["JWT_PRIVATE_KEY"]' apps/seafile/seafile-secrets.sops.yaml | base64 -d
> ```

---

## Deployment via Flux

Seafile wird wie alle anderen Services über Flux CD deployed — kein manuelles `kubectl apply` nötig.

```bash
# 1. Secret erstellen und verschlüsseln (siehe oben)

# 2. Ingress vorbereiten (gitignored — Hostname bleibt lokal)
cp apps/seafile/seafile-ingress.yaml.example apps/seafile/seafile-ingress.yaml
vim apps/seafile/seafile-ingress.yaml  # Hostname eintragen
kubectl apply -f apps/seafile/seafile-ingress.yaml

# 3. Committen und pushen → Flux reconciled automatisch
git add apps/seafile/seafile-secrets.sops.yaml
git commit -m "feat(seafile): add encrypted secrets"
git push

# 4. Optional: Reconcile manuell anstoßen
flux reconcile kustomization apps --with-source
```

Status beobachten:
```bash
kubectl get pods -n seafile -w
```

Seafile initialisiert sich beim ersten Start automatisch (DB-Setup, Admin-Account). Der erste Start dauert ca. 1–2 Minuten. Admin-Account ist danach über die Web UI zugänglich.

---

## Hinweise

- **`SEAFILE_SERVER_PROTOCOL`** muss im Deployment gesetzt sein (`http` oder `https`) — fehlt diese Variable, generiert das Image `SERVICE_URL` und `FILE_SERVER_ROOT` nicht korrekt, und der Browser bekommt eine `localhost`-URL für Uploads (Network Error). Der Wert ist nicht sensitiv und steht direkt im Manifest.
- **`seafile-secrets.sops.yaml` darf keine k8s-Laufzeit-Metadaten enthalten** (`uid`, `resourceVersion`, `creationTimestamp`) — diese verursachen Konflikte beim Flux-Apply.
- **Readiness Probe**: Der Seafile-Pod bleibt bis zu ~2 Minuten auf `0/1`, während Seahub startet. Das ist normal.
- **JWT_PRIVATE_KEY**: Kein abgeleiteter Wert — ein unabhängig generierter Zufalls-String für die JWT-Token-Signierung.
