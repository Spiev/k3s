# Kubernetes Learning Path — Raspberry Pi 5

Goal: step-by-step introduction to Kubernetes with k3s on two Raspberry Pi 5 (8 GB RAM each). Server-Node: 256 GB NVMe, Agent-Node (after migration): 2 TB NVMe. Full migration of all Docker services is the target.

→ [Architecture Overview](./architecture.md) — big picture, network flow, components

---

## Architecture decisions (upfront)

### Why k3s?
- Lightweight, ARM64-ready, already includes Traefik (Ingress), CoreDNS, Flannel (CNI), and local-path-provisioner
- Production-ready, but significantly simpler than "full" Kubernetes
- Easy multi-node expansion: just join an agent

### Why local-path as storage?

`local-path-provisioner` is k3s built-in and the right choice for this setup:
- Data lives directly on the node filesystem — like Docker volumes, directly readable and backupable
- Services are pinned to a fixed node anyway (hardware/storage capacity) → no benefit from replication
- Backup via Restic directly from the filesystem, no snapshot overhead

→ Full rationale: [`docs/decisions/storage.md`](decisions/storage.md)

### Why Flux CD as GitOps?
- Lighter than ArgoCD (fits better on a Raspi)
- Pull-based: no webhook needed, works behind NAT
- Compatible with SOPS → encrypted secrets can go into the Git repo

---

## Phase 0 — Hardware & OS (Day 1–2)

### Set up Raspberry Pi 5

**OS: Raspberry Pi OS Lite (64-bit, Bookworm)**
Ships all hardware tools natively (`raspi-config`, `vcgencmd`, `rpi-eeprom-update`) — important for headless operation and future hardware adjustments. k3s runs on Raspberry Pi OS without issues.

1. Flash Raspberry Pi OS Lite (64-bit) directly to NVMe using the Raspberry Pi Imager
2. First boot: update EEPROM (`sudo rpi-eeprom-update -a`)
3. Enable cgroups in `/boot/firmware/cmdline.txt`, disable swap

Details: [docs/01-os-setup.md](./platform/01-os-setup.md)

**Why NVMe matters:**
Kubernetes writes constantly to disk (etcd, logs, volumes). SD cards die within weeks from this. NVMe is not optional here.

---

## Phase 1 — k3s & Core concepts (Week 1)

### Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
# Copy kubeconfig for your user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### What k3s ships out of the box
- **Traefik** — Ingress Controller (HTTP/HTTPS routing into the cluster)
- **CoreDNS** — cluster-internal DNS (`service.namespace.svc.cluster.local`)
- **Flannel** — networking between pods
- **local-path-provisioner** — storage directly on the node filesystem (used in production)
- **Etcd** — cluster state database (runs embedded)

### Learning core concepts

The most important Kubernetes objects, in order of understanding:

```
Pod → smallest unit, one or more containers
Deployment → manages pods (desired count, rolling updates)
Service → stable network endpoint for pods (ClusterIP / NodePort / LoadBalancer)
ConfigMap → configuration as key-value pairs (not a secret)
Secret → like ConfigMap, but base64-encoded (and encryptable with SOPS + age)
PersistentVolume (PV) → actual storage
PersistentVolumeClaim (PVC) → pods "request" storage via PVCs
Namespace → logical separation of resources
Ingress / IngressRoute → external HTTP(S) routing into services
```

**First steps with kubectl:**
```bash
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get services --all-namespaces

# Inspect an object in detail
kubectl describe pod <name> -n <namespace>
# Pod logs
kubectl logs <pod-name> -n <namespace>
# Shell into a pod
kubectl exec -it <pod-name> -n <namespace> -- sh
```

**Recommended learning resource:** [Kubernetes Docs — Concepts](https://kubernetes.io/docs/concepts/)
Particularly relevant: Workloads, Services & Networking, Storage.

---

## Phase 2 — Networking & Ingress (Week 1–2)

k3s ships with Traefik. This is your nginx replacement inside the cluster.

### Understanding service types
```
ClusterIP    → only reachable within the cluster (default)
NodePort     → open a port on the node (for testing, not production)
LoadBalancer → assign an external IP (requires MetalLB on bare metal)
```

### Install MetalLB

k3s ships a built-in ServiceLB (Klipper) that simply binds `LoadBalancer` services to the node IP. For a stable VIP that can migrate between nodes in a multi-node setup, MetalLB is needed.

**Step 1 — Disable k3s ServiceLB** (in `/etc/rancher/k3s/config.yaml`):
```yaml
disable:
  - servicelb
```
`sudo systemctl restart k3s`

**Step 2 — Deploy MetalLB:**
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

**Step 3 — Configure IP pool** (`infrastructure/metallb/metallb.yaml`):
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.178.200-192.168.178.220   # free range in the home network
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

From now on, every `type: LoadBalancer` service gets a dedicated IP from the pool — no port sharing, no conflicts between services.

> **Why MetalLB instead of kube-vip?** MetalLB is purpose-built for exactly this task and much more common in professional on-premises Kubernetes environments. kube-vip primarily solves Control Plane HA (3+ nodes) — not relevant in this setup.

### Configure Traefik

Traefik in k3s runs as an `IngressController`. There are two ways to define routing:
- **Ingress** (Kubernetes standard, simpler)
- **IngressRoute** (Traefik-specific, more powerful — recommended)

### cert-manager / TLS

**Not needed yet.** During migration, nginx (on the old Raspi) terminates TLS — Traefik only receives HTTP requests internally and does not need its own certificates.

cert-manager only comes into play when deciding whether Traefik replaces nginx as the external entry point. That is a later decision (see Phase 8).

---

## Phase 3 — Storage: local-path (Week 2)

k3s already ships with `local-path-provisioner` — no installation needed.

### Concepts

```yaml
# PersistentVolumeClaim — how pods request their storage
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

Data lands at `/var/lib/rancher/k3s/storage/<pvc-name>/` on the node — directly readable, directly backupable with Restic.

### Backup

```
/var/lib/rancher/k3s/storage/<pvc-name>/
       │  directly readable
       ▼
  Restic → Hetzner S3
```

Details: [docs/operations/backup-restore.md](./operations/backup-restore.md)

### Path to the second node

Once all services are running on k3s and the old Raspi leaves Docker:
1. Stop Docker, back up data
2. Install k3s agent and join the cluster
3. Explicitly pin services to desired nodes via `nodeSelector`

---

## Phase 4 — First migration: FreshRSS (Week 3)

FreshRSS is ideal as the first candidate:
- A single volume (`./config`) — no database cluster
- No complex network setup
- Easy to roll back (Docker container keeps running in parallel until cutover)

### Migration strategy

```
1. Deploy FreshRSS in k3s (empty volume)
2. Copy data from Docker volume into local-path PVC
3. Test (in parallel with the old container)
4. Switch DNS/Traefik to k3s
5. Stop Docker container
```

### Data migration (Docker → local-path PVC)

```bash
# Temporary pod that mounts the PVC
kubectl run migration --image=alpine --restart=Never \
  -n freshrss --overrides='
{
  "spec": {
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "freshrss-config"}}],
    "containers": [{
      "name": "migration",
      "image": "alpine",
      "command": ["sleep", "3600"],
      "volumeMounts": [{"name": "data", "mountPath": "/data"}]
    }]
  }
}'

# Copy data from the old server into the pod
kubectl cp /path/to/docker/freshrss/config/. freshrss/migration:/data/
```

The finished manifests for FreshRSS will live in `apps/freshrss/` in the repo.

---

## Phase 4b — Second migration: Seafile (Week 3–4)

Seafile is the ideal next step after FreshRSS, because it introduces all the new concepts needed for Flux/GitOps: multiple related pods, service-to-service communication, and secrets.

### Architecture in k3s

The official `seafileltd/seafile-mc` image contains Seafile, Seahub **and** memcached — just 2 pods:

```
[Ingress/Traefik]
      ↓
[seafile-mc pod]  ←→  ClusterIP Service  ←→  [MariaDB pod]
      ↓
[seafile-data PVC]  +  [mariadb-data PVC]
```

### New concepts compared to FreshRSS

- **Multiple Deployments in one Namespace** — Seafile and MariaDB as separate Deployments
- **Service-to-service communication** — Seafile talks to MariaDB via `mariadb.seafile.svc.cluster.local` (CoreDNS)
- **SOPS in practice** — DB password, Seafile `SECRET_KEY`, admin credentials
- **Startup ordering** — MariaDB must be ready before Seafile starts (`initContainers` or `startupProbe`)

### Why Seafile should be migrated carefully despite its sync advantage

Seafile is sync-based: file blobs exist locally on all clients. A cluster outage therefore means no data loss. **What would be lost:** version history, share links, library metadata (all in MariaDB). Backups of MariaDB are still important.

### Migration strategy

```
1. Deploy Seafile in k3s (empty DB + empty volume)
2. Import MariaDB dump from old server
3. Copy Seafile data library into new PVC (rsync or kubectl cp)
4. Switch Seafile client on one device to new URL → test sync
5. Switch DNS, update all clients to new URL
6. Stop Docker containers
```

---

## Phase 5 — GitOps with Flux CD (Week 4–5)

### Repository structure (target)

```
k3s/
├── clusters/
│   └── raspi/              ← cluster-specific Flux configuration
│       ├── flux-system/    ← Flux itself (auto-generated)
│       └── apps.yaml       ← points to apps/
├── apps/
│   ├── freshrss/           ← FreshRSS manifests
│   └── cert-manager/
├── infrastructure/
│   └── traefik/            ← Traefik configuration
└── docs/
```

### Moving Traefik out of k3s

Traefik is built into k3s and tied to the k3s version — version management and Renovate tracking are not possible this way. Flux solves this cleanly:

**Step 1 — Disable built-in Traefik** (in `/etc/rancher/k3s/config.yaml` on the Pi):

```yaml
disable:
  - traefik
  - local-storage
```

`sudo systemctl restart k3s` — Traefik is removed from the cluster.

**Step 2 — Traefik as a Flux HelmRelease in the repo** (`infrastructure/traefik/helmrelease.yaml`):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: kube-system
spec:
  url: https://traefik.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: kube-system
spec:
  chart:
    spec:
      chart: traefik
      version: "34.4.0"   # Renovate tracks this automatically
      sourceRef:
        kind: HelmRepository
        name: traefik
```

Flux deploys it automatically on the next sync. Renovate natively recognises `HelmRelease` resources and proposes updates as PRs.

> **Important:** Disable Traefik in k3s first, then deploy Flux — otherwise there are CRD ownership conflicts (both try to manage the same Gateway CRDs).

> **HelmChart vs. HelmRelease:** k3s has its own `HelmChart` type (`helm.cattle.io/v1`) which is also supported by Renovate. Flux uses `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) with a separate `HelmRepository` object. Both work, but once Flux is present, `HelmRelease` is the more consistent approach.

### Install & bootstrap Flux

```bash
curl -s https://fluxcd.io/install.sh | sudo bash

flux bootstrap github \
  --owner=<your-github-user> \
  --repository=k3s \
  --branch=main \
  --path=clusters/raspi \
  --personal
```

Flux sets itself up and monitors this repository from now on. Every commit to `main` → Flux deploys automatically.

---

## Phase 6 — Secrets Management (Week 4)

Secrets in Kubernetes are only base64-encoded, not encrypted. For a public GitHub repo, SOPS + age is used to encrypt secret values before committing.

### SOPS + age

SOPS is built into Flux's `kustomize-controller` — no extra controller needed. Secrets are standard Kubernetes `Secret` manifests with encrypted values, stored as `*.sops.yaml` files.

```bash
# Install tools (Arch Linux)
sudo pacman -S age sops

# Generate age key
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# → note the public key, add it to .sops.yaml in the repo root

# Encrypt a secret
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=FTLCONF_webserver_api_password="secret" \
  --dry-run=client -o yaml > apps/pihole/pihole-secret.sops.yaml

SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --encrypt --in-place apps/pihole/pihole-secret.sops.yaml
# → safe to commit to the public repo
```

Flux decrypts the `*.sops.yaml` files in memory during reconciliation and applies plain Secrets to the cluster — no decrypted values ever touch disk or Git.

> **Important:** Back up the age private key immediately — store it in Vaultwarden. Full setup and recovery: [docs/platform/05-sops.md](./platform/05-sops.md)

---

## Phase 7 — Monitoring (Week 5)

**kube-prometheus-stack** installs Prometheus, Grafana, and Alertmanager in a single Helm chart — including pre-built dashboards for node metrics, pod resources, PVCs, and Kubernetes objects.

Raspberry Pi hardware metrics (CPU temperature etc.) are provided by `node_exporter`, which is already included in the stack.

Optional: Prometheus integration with Home Assistant for automations based on cluster metrics.

Details: [docs/operations/monitoring.md](./operations/monitoring.md)

---

## Phase 8 — Multi-Node: add the old Raspi (Future)

**Prerequisite:** The old Raspi (Raspi 5, 8 GB RAM, 2 TB NVMe) only runs as a k3s Agent-Node once all its Docker services are fully migrated to k3s. Both roles simultaneously are not possible.

Home Assistant then runs on the Agent-Node with `hostNetwork: true` and `nodeAffinity` for the Zigbee dongle — no re-plugging needed.

Steps when the time comes:
1. **Set up MetalLB** (if not already done) — configure VIP pool so services get a stable IP that can migrate between nodes (see Phase 2)
2. Stop Docker services, back up data
3. Install k3s agent on the old Raspi:

```bash
# Get token from the server node
sudo cat /var/lib/rancher/k3s/server/node-token

# On the old Raspi:
curl -sfL https://get.k3s.io | K3S_URL=https://<raspi5-ip>:6443 \
  K3S_TOKEN=<token> sh -
```

3. Pin services to desired nodes via `nodeSelector`.

**Node roles:**
- **Server-Node** (Raspi 5): Control Plane, API server, scheduler, etcd
- **Agent-Node** (old Raspi): workloads only, no Control Plane

---

## Non-goals (deliberately excluded)

- **High-Availability Control Plane**: Only makes sense with 3+ nodes. Single-server setup is sufficient for 2 nodes.
- **Kubernetes Dashboard**: Grafana covers this better.
- **Multi-cluster setups**: Not applicable to this use case.

---

## Document order

1. `docs/platform/01-os-setup.md` — NVMe boot, Raspberry Pi OS, cgroups
2. `docs/platform/02-k3s-install.md` — k3s with Dual-Stack (IPv4+IPv6), kubectl (local + remote), first steps
3. `docs/platform/03-metallb.md` — set up MetalLB (LoadBalancer VIPs for bare metal)
4. `docs/services/freshrss.md` — migrate FreshRSS
5. `docs/platform/05-sops.md` — set up SOPS + age (prerequisite for all further secrets)
6. `docs/services/pihole.md` — Pi-hole: DNS via LoadBalancer
7. `docs/services/seafile.md` — migrate Seafile (multi-container, secrets)
8. `docs/services/immich.md` — migrate Immich (Restic restore strategy, large volume)
9. `docs/operations/monitoring.md` — Prometheus + Grafana
10. `docs/operations/backup-restore.md` — backup & restore, critical secrets
