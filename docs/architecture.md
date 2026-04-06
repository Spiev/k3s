# Architecture Overview

---

## Hardware

| Node | Role | RAM | NVMe | Status |
|---|---|---|---|---|
| Raspi 5 "new" | k3s Server-Node (Control Plane) | 8 GB | 256 GB | k3s |
| Raspi 5 "old" | k3s Agent-Node (Workloads + Storage) | 8 GB | 2 TB | Docker → k3s (after migration) |

Both nodes are identical hardware (Raspberry Pi 5, 8 GB RAM). The old Raspi has significantly more storage thanks to its 2 TB NVMe — it will be the primary workload node for large volumes (Immich, Paperless).

---

## Big picture (target state)

```
                           Internet
                               │
                        ┌──────▼──────┐
                        │   Router    │  Port 80/443
                        └──────┬──────┘
                               │
               ┌───────────────▼──────────────────────────────────────┐
               │                   k3s Cluster                        │
               │                                                      │
               │  ┌─────────────────────┐  ┌──────────────────────┐   │
               │  │  Server-Node        │  │  Agent-Node          │   │
               │  │  Raspi 5 "new"      │  │  Raspi 5 "old"       │   │
               │  │  256 GB NVMe        │  │  2 TB NVMe           │   │
               │  │                     │  │                      │   │
               │  │  Control Plane      │  │  [freshrss]          │   │
               │  │  Traefik (Ingress)  │  │  [seafile]           │   │
               │  │  CoreDNS            │  │  [immich]            │   │
               │  │  Pi-hole (DNS)      │  │  [paperless]         │   │
               │  │                     │  │  [homeassistant] ←┐  │   │
               │  └─────────────────────┘  │  [mosquitto]      │  │   │
               │                           └───────────────────┼──┘   │
               │                                               │      │
               │                                                      │
               └──────────────────────────────────────────────────────┘
                                                    │
                                            Zigbee USB dongle
                                            plugged into Agent-Node
```

---

## Network: how a request flows through the cluster

### During migration (transition phase)

nginx remains the external entry point — it knows the public IP, holds the certificates, and all Docker services still run behind it. For k3s services, nginx simply forwards to the new Raspi:

```
Browser: https://freshrss.example.com
         │
         ▼
    Router → nginx (old Raspi, :443)
         │  TLS termination, rate limiting, security headers, Fail2ban
         │  proxy_pass → http://raspi5-ip:80
         ▼
    Traefik (new Raspi, :80)
         │  checks: which domain? → IngressRoute rules
         ▼
    Service "freshrss" (ClusterIP, cluster-internal)
         │
         ▼
    Pod "freshrss-xxxx"
         │
         ▼
    PVC → local-path volume → NVMe
```

Two proxy hops, but clean separation of concerns: nginx = external security layer, Traefik = internal Kubernetes routing. No DNS change needed, both Raspis run independently.

### After full migration (target state)

Once all services run on k3s, nginx can be consolidated:

```
Browser: https://freshrss.example.com
         │
         ▼
    Router → Traefik (new Raspi, :443)
         │  TLS via cert-manager (Let's Encrypt)
         │  rate limiting + security headers via Traefik Middleware
         ▼
    Service → Pod → local-path → NVMe
```

Traefik then takes over everything nginx does today. Fail2ban can run as a DaemonSet in the cluster or be replaced by Traefik-native rate limits.

**This decision does not need to be made now.** Only once all services are migrated does a comparison make sense: nginx is battle-tested and configured, Traefik is more k8s-native.

---

## Kubernetes objects per service

Every migrated service consists of the same building blocks:

```
Namespace
  ├── Deployment          ← "run N copies of this container"
  │     └── Pod(s)        ← the actual container
  ├── Service             ← stable internal network endpoint
  ├── PersistentVolumeClaim (PVC)  ← "I need X GB of storage"
  │     └── PersistentVolume (PV)  ← provisioned by local-path
  ├── ConfigMap           ← configuration (not a secret)
  ├── SealedSecret        ← encrypted secret (safe to commit to Git)
  └── IngressRoute        ← "this domain goes to this service"
```

Example FreshRSS (simplest case, 1 container):
```
Namespace: freshrss
  ├── Deployment: freshrss (1 pod, image: lscr.io/linuxserver/freshrss)
  ├── Service: freshrss (ClusterIP → port 80)
  ├── PVC: freshrss-config (5Gi, local-path)
  └── IngressRoute: freshrss.example.com → Service freshrss
```

Example Seafile (2 containers, service-to-service):
```
Namespace: seafile
  ├── Deployment: seafile (seafileltd/seafile-mc)
  │     └── talks to MariaDB via: mariadb.seafile.svc.cluster.local
  ├── Deployment: mariadb
  ├── Service: seafile (ClusterIP)
  ├── Service: mariadb (ClusterIP, cluster-internal only)
  ├── PVC: seafile-data
  ├── PVC: mariadb-data
  ├── SealedSecret: seafile-secrets (DB password, SECRET_KEY)
  └── IngressRoute: seafile.example.com → Service seafile
```

---

## Storage: local-path

k3s ships with the `local-path-provisioner` built in. Data lives directly on the node filesystem:

```
Pod writes data
       │
       ▼
  PVC (request: "5Gi, ReadWriteOnce")
       │  local-path fulfils the request
       ▼
  /var/lib/rancher/k3s/storage/<pvc-name>/   ← directly on the NVMe
```

PVCs automatically receive a `nodeAffinity` for the node on which they were created. This technically enforces what is already intended in this setup: services are pinned to a fixed node (due to hardware or storage capacity).

**Storage planning with 2 nodes:**
Large volumes (Immich library, Paperless documents) go on the Agent-Node with 2 TB NVMe — via an explicit `nodeSelector` in the Deployment. Small volumes (FreshRSS, Seafile) go on the Server-Node.

→ Migration strategy for Immich (1.5 TB library): [`docs/services/immich.md`](services/immich.md)

**Backup strategy:**
```
/var/lib/rancher/k3s/storage/<pvc-name>/
       │  directly readable (like Docker volumes)
       ▼
  Restic → Hetzner S3
```

→ Decision against Longhorn: [`docs/decisions/storage.md`](decisions/storage.md)

---

## GitOps: how changes reach the cluster

```
  Local laptop
       │  git push
       ▼
  GitHub repository (this repo)
       │
       │  Flux CD (running in the cluster) polls every 1 minute
       ▼
  Flux detects change → applies manifests
       │
       ▼
  k3s cluster (target state = Git state)
```

No webhook needed. Flux pulls actively — works behind NAT without a public IP for the cluster ingress.

**Sealed Secrets in the GitOps flow:**
```
Laptop: kubectl create secret ... | kubeseal → SealedSecret.yaml
        git commit + push
        ↓
Flux deploys SealedSecret into the cluster
        ↓
Sealed Secrets controller decrypts → real secret in the cluster
        ↓
Pod reads secret (password, API key etc.)
```

---

## Current state vs. target state

```
Today                               Target (after migration)
──────────────────────────────      ──────────────────────────────────────
Raspi 5 "new" (256 GB)              Raspi 5 "new": k3s Server-Node
  └── k3s (empty)                     └── Control Plane, Traefik, CoreDNS

Raspi 5 "old" (2 TB)                Raspi 5 "old": k3s Agent-Node
  └── Docker                           └── FreshRSS
        └── FreshRSS                   └── Seafile
        └── Immich                     └── Immich        (2 TB NVMe)
        └── Paperless                  └── Paperless     (2 TB NVMe)
        └── Home Assistant             └── Home Assistant (hostNetwork +
        └── Teslamate                  └── Teslamate      USB nodeAffinity)
        └── Pi-hole                    └── Pi-hole
        └── Nginx Proxy                └── Mosquitto
        └── Mosquitto                  └── Matter Hub
        └── Matter Hub
```

Both Pis are identical hardware (Raspi 5, 8 GB RAM) — a full migration to k3s is realistic. Home Assistant runs on the Agent-Node with `hostNetwork: true` and `nodeAffinity` for the Zigbee dongle — no re-plugging needed. nginx stays as the external proxy for now, and can be replaced by Traefik later.

---

## Component overview

| Component | Type | Purpose | Where |
|---|---|---|---|
| k3s | Kubernetes distribution | Cluster orchestration | Raspi 5 |
| nginx | Reverse proxy | External entry point, TLS, Fail2ban (runs on old Raspi) | Docker |
| Traefik | Ingress Controller | Internal k8s routing (may replace nginx later) | k3s built-in |
| CoreDNS | DNS | Cluster-internal DNS | k3s built-in |
| Flannel | CNI | Pod networking | k3s built-in |
| MetalLB | Load Balancer | External IPs for services on bare metal (replaces k3s ServiceLB) | Installed via kubectl |
| local-path-provisioner | Storage | Persistent volumes directly on node filesystem | k3s built-in |
| cert-manager | Controller | Let's Encrypt TLS — only needed when Traefik replaces nginx | Later |
| Flux CD | GitOps | Automated deployment | Installed via flux CLI |
| Sealed Secrets | Controller | Secret encryption | Installed via kubectl |
| Prometheus + Grafana | Monitoring | Metrics & dashboards | kube-prometheus-stack |
