# k3s Homelab

Kubernetes infrastructure on a Raspberry Pi 5 (8 GB RAM, 256 GB NVMe). Migration of existing Docker services from [docker-runtime](../docker-runtime).

**Hardware:** 2× Raspberry Pi 5 (8 GB RAM) — Server-Node 256 GB NVMe, Agent-Node 2 TB NVMe

**Stack:** k3s · local-path · Traefik · SOPS · Flux CD

---

## Documentation

| Document | Content |
|---|---|
| **Architecture** | |
| [Architecture Overview](docs/architecture.md) | Big picture, network flow, components — good starting point |
| [Decision: Storage](docs/decisions/storage.md) | local-path instead of Longhorn — rationale and trade-offs |
| [Decision: Ingress Security](docs/decisions/ingress-security.md) | CrowdSec instead of fail2ban — Traefik-native security layer |
| **Platform Setup** | |
| [OS Setup](docs/platform/os-setup.md) | Raspberry Pi OS on NVMe, EEPROM, cgroups |
| [Install k3s](docs/platform/k3s-install.md) | k3s with Dual-Stack (IPv4+IPv6), kubectl, first steps |
| [MetalLB](docs/platform/metallb.md) | LoadBalancer VIPs for Bare Metal (DNS, stable service IPs) |
| [SOPS + age](docs/platform/sops.md) | Encrypting secrets for a public Git repo |
| [Flux CD](docs/platform/flux.md) | GitOps: automated deployment from Git |
| **Service Migrations** | |
| [FreshRSS](docs/services/freshrss.md) | Deploy & migrate FreshRSS |
| [Pi-hole](docs/services/pihole.md) | Pi-hole: DNS via LoadBalancer + Ingress |
| [Seafile](docs/services/seafile.md) | Migration: Seafile, multi-container, Secrets |
| [Immich](docs/services/immich.md) | Migration: Immich, Restic restore strategy (1.5 TB library) |
| [Vaultwarden](docs/services/vaultwarden.md) | Password manager: concept, SSO, YubiKey, backup, Tier-0 emergency plan |
| **Operations** | |
| [Shutdown & Startup](docs/operations/shutdown-startup.md) | Gracefully shutting down and starting up the cluster |
| [Monitoring](docs/operations/monitoring.md) | kube-prometheus-stack, Grafana, Alertmanager |
| [Renovate](docs/operations/renovate.md) | Automated dependency updates via GitHub Action |
| [Backup & Restore](docs/operations/backup-restore.md) | Cluster rebuild, volume restore, critical secrets |
| [Image Updates](docs/operations/update-images.md) | Manual image update, crictl pre-pull for RWO PVCs |

---

## Structure

```
apps/           Kubernetes manifests per service
  freshrss/     Namespace, PVC, Deployment, Service, Ingress
  pihole/       Namespace, Deployment, Service (LoadBalancer + Ingress)
  seafile/      Namespace, PVCs, StatefulSet (MariaDB), Deployments (Seafile, Redis)

docs/           Guides and architecture documentation

infrastructure/ Cluster infrastructure (Monitoring, Traefik config)
                → managed by Flux CD

clusters/       Flux CD configuration
  raspi/        Cluster entrypoint
```

---

## Migration Status

| Service | Status | Notes |
|---|---|---|
| FreshRSS | ✅ Migrated | Running on k3s, volume migration |
| Pi-hole | ✅ Migrated | DNS via LoadBalancer + Ingress |
| Seafile | ✅ Migrated | Set up directly in k3s |
| Immich | Open | Restic restore strategy (no space to copy) — after Agent-Node join |
| Paperless | Open | |
| Teslamate | Open | |
| Home Assistant | Planned (Agent-Node) | `hostNetwork` + `nodeAffinity` for Zigbee dongle |
| Vaultwarden | Concept | Google SSO (OIDC fork), YubiKey 2FA — Kubernetes deployment pending |
