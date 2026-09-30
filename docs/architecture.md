# Architecture Overview

---

## Hardware

| Node | Hostname | Role | RAM | NVMe |
|---|---|---|---|---|
| Raspi 5 "new" | `k3s` | Control Plane (Server-Node) | 8 GB | 4 TB |
| Raspi 5 "old" | `k3s-a1` | Agent-Node — all workloads | 8 GB | 2 TB |

Both nodes are identical hardware (Raspberry Pi 5, 8 GB RAM). The Server-Node (`k3s`) runs only the control plane and Traefik — pinned there via `nodeSelector` so `externalTrafficPolicy: Local` preserves the real client IP (see `infrastructure/traefik/traefik-config.yaml`). Every application workload, including Immich, runs on the Agent-Node (`k3s-a1`) — this differs from the original plan (see [Immich Migration](services/immich.md)), which assumed Immich would stay on the Server-Node for storage locality; in practice it was migrated onto the Agent-Node with the rest of the fleet instead.

---

## Big picture (current state)

```
                           Internet
                               │
                        ┌──────▼──────┐
                        │   Router    │  Port 80/443 forwarded directly to k3s
                        └──────┬──────┘
                               │
               ┌───────────────▼──────────────────────────────────────┐
               │                   k3s Cluster                        │
               │                                                      │
               │  ┌─────────────────────┐  ┌──────────────────────┐   │
               │  │  Server-Node (k3s)  │  │  Agent-Node (k3s-a1) │   │
               │  │  4 TB NVMe          │  │  2 TB NVMe           │   │
               │  │                     │  │                      │   │
               │  │  Control Plane      │  │  [immich] (1.5 TB)   │   │
               │  │  Traefik (Ingress)  │  │  [pihole] (DNS)      │   │
               │  │  CoreDNS            │  │  [freshrss]          │   │
               │  │  cert-manager       │  │  [seafile]           │   │
               │  │                     │  │  [paperless]         │   │
               │  │                     │  │  [teslamate]         │   │
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

There is no Docker Compose homelab anymore, and no separate nginx edge proxy — that migration is complete. Traefik on the Server-Node is the single internet-facing entry point.

---

## Network: how a request flows through the cluster

```
Browser: https://<service>.example.com
         │
         ▼
    Router (Fritzbox) → forwards 80/443 directly → Traefik (Server-Node k3s)
         │  TLS termination (manually-imported multi-SAN cert today — cert-manager
         │  migration open, see docs/security-hardening-notes.md, local-only)
         │  rate limiting + security headers + LAN-only IP allowlist via Traefik
         │  Middleware (infrastructure/traefik/traefik-middlewares.yaml)
         ▼
    Service (ClusterIP, cluster-internal)
         │
         ▼
    Pod (scheduled on whichever node the workload runs on — almost
         always the Agent-Node; only Traefik/control-plane pin to the
         Server-Node)
         │
         ▼
    PVC → local-path volume → NVMe (on whichever node the pod lives on)
```

Brute-force/scanner protection (CrowdSec) is decided but not yet implemented — see [Decision: Ingress Security](decisions/ingress-security.md).

---

## Storage

`local-path-provisioner` (k3s built-in) stores data at `/var/lib/rancher/k3s/storage/<pvc-name>/` — directly on NVMe, directly backupable with Restic. PVCs automatically get `nodeAffinity` for the node they were created on.

Immich (~1.5 TB) and every other service's volumes live on the Agent-Node's 2 TB NVMe. The Server-Node's larger 4 TB disk currently only holds the control plane — there is no storage-heavy workload pinned there today, despite the original plan (see Hardware section above).

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

**Not everything is Flux-managed.** The real per-service Ingress manifests (`apps/*/**-ingress.yaml`) are gitignored by design (they'd otherwise leak real hostnames into this public repo) and are applied manually via `kubectl apply -f` from a workstation copy — this is a known gap, tracked in `docs/security-hardening-notes.md` (local-only).

---

## Component overview

| Component | Type | Purpose | Where |
|---|---|---|---|
| k3s | Kubernetes distribution | Cluster orchestration | Both Raspi 5 nodes |
| Traefik | Ingress Controller | Internet-facing entry point, TLS, rate limiting, security headers | k3s built-in, pinned to Server-Node |
| CoreDNS | DNS | Cluster-internal DNS | k3s built-in |
| Flannel | CNI | Pod networking | k3s built-in |
| MetalLB | Load Balancer | External IPs for services on bare metal (replaces k3s ServiceLB) | Installed via kubectl |
| local-path-provisioner | Storage | Persistent volumes directly on node filesystem | k3s built-in |
| cert-manager | Controller | Let's Encrypt TLS — installed and `Ready`, but ingresses still use a manually-imported cert; migration to cert-manager-issued certs is open (see `docs/security-hardening-notes.md`, local-only) | `cert-manager` namespace |
| Flux CD | GitOps | Automated deployment | Installed via flux CLI |
| SOPS + age | Tool | Secret encryption (built into kustomize-controller) | Flux built-in, age key bootstrapped manually |
| Prometheus + Grafana | Monitoring | Metrics & dashboards | kube-prometheus-stack |
| Ansible | Host/OS config | Firewall (UFW), sysctl — the layer below Flux | `ansible/`, see [Node Configuration](decisions/node-configuration.md) |

→ Current migration progress: [README — Migration Status](../README.md#migration-status)
