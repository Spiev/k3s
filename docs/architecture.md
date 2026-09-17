# Architecture Overview

---

## Hardware

| Node | Role | RAM | NVMe | Status |
|---|---|---|---|---|
| Raspi 5 "new" | k3s Server-Node (Control Plane + Immich) | 8 GB | 4 TB | k3s |
| Raspi 5 "old" | k3s Agent-Node (all other workloads) | 8 GB | 2 TB | Docker → k3s (after migration) |

Both nodes are identical hardware (Raspberry Pi 5, 8 GB RAM). The Server-Node carries the largest disk and runs the Control Plane plus the single storage-heavy service, Immich (~1.5 TB library). All other services run on the Agent-Node, including Home Assistant (Zigbee dongle attached there).

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
               │  │  4 TB NVMe          │  │  2 TB NVMe           │   │
               │  │                     │  │                      │   │
               │  │  Control Plane      │  │  [pihole] (DNS)      │   │
               │  │  Traefik (Ingress)  │  │  [freshrss]          │   │
               │  │  CoreDNS            │  │  [seafile]           │   │
               │  │                     │  │  [paperless]         │   │
               │  │  [immich] (1.5 TB)  │  │  [teslamate]         │   │
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

## Storage

`local-path-provisioner` (k3s built-in) stores data at `/var/lib/rancher/k3s/storage/<pvc-name>/` — directly on NVMe, directly backupable with Restic. PVCs automatically get `nodeAffinity` for the node they were created on.

The storage-heavy service (Immich, ~1.5 TB) goes on the Server-Node via `nodeSelector`. All other volumes (Pi-hole, FreshRSS, Seafile, Paperless, Teslamate) go on the Agent-Node.

→ [Storage Decision](decisions/storage.md) · [Immich Migration](services/immich.md) · [Backup & Restore](operations/backup-restore.md)

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

Secrets are encrypted with SOPS + age and committed as `*.sops.yaml` files. Flux decrypts them in memory during reconciliation — decrypted values never touch disk or Git. → [SOPS + age](platform/sops.md)

---

## Starting point vs. target state

```
Starting point (all Docker)         Target (all k3s)
──────────────────────────────      ──────────────────────────────────────
Raspi 5 "new" (256 GB → 4 TB)      Raspi 5 "new": k3s Server-Node (4 TB)
  └── k3s (empty)                     └── Control Plane, Traefik, CoreDNS
                                      └── Immich        (4 TB NVMe, 1.5 TB)

Raspi 5 "old" (2 TB)                Raspi 5 "old": k3s Agent-Node
  └── Docker                           └── Pi-hole
        └── FreshRSS                   └── FreshRSS
        └── Immich                     └── Seafile
        └── Paperless                  └── Paperless
        └── Home Assistant             └── Teslamate
        └── Teslamate                  └── Home Assistant (hostNetwork +
        └── Pi-hole                    └── Mosquitto      USB nodeAffinity)
        └── Nginx Proxy                └── Matter Hub
        └── Mosquitto
        └── Matter Hub
```

Both Pis are identical hardware (Raspi 5, 8 GB RAM) — a full migration to k3s is realistic. The Server-Node hosts Immich (the only storage-heavy service) alongside the Control Plane; every other service runs on the Agent-Node. Home Assistant runs on the Agent-Node with `hostNetwork: true` and `nodeAffinity` for the Zigbee dongle — no re-plugging needed. nginx stays as the external proxy for now, and can be replaced by Traefik later.

→ Current migration progress: [README — Migration Status](../README.md#migration-status)

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
| SOPS + age | Tool | Secret encryption (built into kustomize-controller) | Flux built-in, age key bootstrapped manually |
| Prometheus + Grafana | Monitoring | Metrics & dashboards | kube-prometheus-stack |
