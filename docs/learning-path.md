# Learning Path — Raspberry Pi 5 k3s Cluster

Step-by-step path from bare hardware to a fully migrated Kubernetes homelab. Each phase links to the detailed guide.

→ [Architecture Overview](./architecture.md) — big picture, network flow, components

---

## Architecture decisions

### Why k3s?
- Lightweight, ARM64-ready, ships Traefik, CoreDNS, Flannel, and local-path-provisioner out of the box
- Production-ready, but significantly simpler than "full" Kubernetes
- Easy multi-node expansion: just join an agent

### Why local-path as storage?
- Data lives directly on the node filesystem — like Docker volumes, directly readable and backupable via Restic
- Services are pinned to a fixed node anyway (hardware/storage capacity) → no benefit from replication
- → Full rationale: [decisions/storage.md](decisions/storage.md)

### Why Flux CD as GitOps?
- Lighter than ArgoCD (fits on a Raspi)
- Pull-based: no webhook needed, works behind NAT
- Compatible with SOPS → encrypted secrets can go into the Git repo

---

## Phase 0 — Hardware & OS

Flash Raspberry Pi OS Lite (64-bit) to NVMe, update EEPROM, enable cgroups, disable swap. NVMe is not optional — SD cards die within weeks from Kubernetes disk writes.

→ [OS Setup](./platform/os-setup.md)

## Phase 1 — k3s & Core Concepts

Install k3s with Dual-Stack (IPv4+IPv6), set up kubectl locally and from the laptop, explore the cluster with first commands and a test deployment.

→ [Install k3s](./platform/k3s-install.md)

## Phase 2 — Networking & Ingress

Understand service types (ClusterIP, NodePort, LoadBalancer). Install MetalLB for stable VIPs on bare metal. Traefik ships with k3s and handles internal HTTP routing; cert-manager comes later when Traefik replaces nginx.

→ [MetalLB](./platform/metallb.md)

## Phase 3 — Storage

k3s ships `local-path-provisioner` — no installation needed. PVCs land at `/var/lib/rancher/k3s/storage/<pvc-name>/` on the node, directly backupable with Restic.

→ [Storage Decision](./decisions/storage.md) · [Backup & Restore](./operations/backup-restore.md)

## Phase 4 — First migration: FreshRSS

Ideal first candidate: single volume, no database, easy rollback. Deploy in k3s, copy data from Docker via a helper pod, switch DNS.

→ [FreshRSS](./services/freshrss.md)

## Phase 4b — Second migration: Seafile

Introduces multi-container setups, service-to-service communication (CoreDNS), SOPS secrets, and startup ordering. Two pods (seafile-mc + MariaDB), two PVCs.

→ [Seafile](./services/seafile.md)

## Phase 5 — GitOps with Flux CD

Flux monitors this repo and deploys automatically on every push. Traefik is moved from k3s built-in to a Flux-managed HelmRelease for independent version management and Renovate tracking.

→ [Flux CD](./platform/flux.md)

## Phase 6 — Secrets Management

SOPS + age encrypts secret values in standard Kubernetes Secret manifests — safe to commit to a public repo. Built into Flux's kustomize-controller, no extra controller needed.

→ [SOPS + age](./platform/sops.md)

## Phase 7 — Monitoring

Primary: node and cluster metrics pushed to Home Assistant via MQTT. Optional: kube-prometheus-stack for deep Kubernetes metrics.

→ [Monitoring](./operations/monitoring.md)

## Phase 8 — Multi-Node: Agent-Node joins

Once all Docker services are migrated, the old Raspi joins as a k3s agent. Home Assistant runs there with `hostNetwork` + `nodeAffinity` for the Zigbee dongle.
