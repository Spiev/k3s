# k3s Homelab

Kubernetes infrastructure on 2× Raspberry Pi 5 (8 GB RAM). Migration from a Docker Compose homelab is complete; both Docker and its edge nginx/fail2ban reverse proxy have been decommissioned.

**Hardware:** 2× Raspberry Pi 5 (8 GB RAM) — Server-Node `k3s` (4 TB NVMe, control plane), Agent-Node `k3s-a1` (2 TB NVMe, all workloads incl. Immich)

**Stack:** k3s · local-path · Traefik · SOPS · Flux CD

---

## Documentation

| Document | Content |
|---|---|
| **Architecture** | |
| [Architecture Overview](docs/architecture.md) | Big picture, network flow, components — good starting point |
| [Decision: Container Orchestration](docs/decisions/container-orchestration.md) | k3s instead of Docker Compose / Swarm / Nomad |
| [Decision: Storage](docs/decisions/storage.md) | local-path instead of Longhorn — rationale and trade-offs |
| [Decision: Ingress Security](docs/decisions/ingress-security.md) | CrowdSec instead of fail2ban — Traefik-native security layer |
| [Decision: Uptime Monitoring](docs/decisions/uptime-monitoring.md) | UptimeRobot instead of self-hosted Uptime Kuma — external reachability checks |
| [Decision: Online Office](docs/decisions/online-office.md) | Collabora Online instead of OnlyOffice — RAM footprint & LibreOffice engine consistency |
| [Decision: Node Configuration](docs/decisions/node-configuration.md) | Ansible for host/OS config (firewall, sysctl) — the non-Flux layer |
| **Platform Setup** | |
| [OS Setup](docs/platform/os-setup.md) | Raspberry Pi OS on NVMe, EEPROM, cgroups |
| [Install k3s](docs/platform/k3s-install.md) | k3s with Dual-Stack (IPv4+IPv6), kubectl, first steps |
| [MetalLB](docs/platform/metallb.md) | LoadBalancer VIPs for Bare Metal (DNS, stable service IPs) |
| [SOPS + age](docs/platform/sops.md) | Encrypting secrets for a public Git repo |
| [Flux CD](docs/platform/flux.md) | GitOps: automated deployment from Git |
| [Firewall (UFW)](docs/platform/firewall.md) | Host firewall as code with Ansible; k3s/multicast rules |
| **Service Migrations** | |
| [FreshRSS](docs/services/freshrss.md) | Deploy & migrate FreshRSS |
| [Pi-hole](docs/services/pihole.md) | Pi-hole: DNS via LoadBalancer + Ingress |
| [Seafile](docs/services/seafile.md) | Migration: Seafile, multi-container, Secrets |
| [Teslamate](docs/services/teslamate.md) | Migration: Teslamate + PostgreSQL + Grafana |
| [Immich](docs/services/immich.md) | Migration: Immich, Restic restore strategy (1.5 TB library) → Server-Node |
| [Vaultwarden](docs/services/vaultwarden.md) | Password manager: concept, SSO, YubiKey, backup, Tier-0 emergency plan |
| **Operations** | |
| [Shutdown & Startup](docs/operations/shutdown-startup.md) | Gracefully shutting down and starting up the cluster |
| [Monitoring](docs/operations/monitoring.md) | kube-prometheus-stack, Grafana, Alertmanager |
| [Renovate](docs/operations/renovate.md) | Automated dependency updates via GitHub Action |
| [Backup & Restore](docs/operations/backup-restore.md) | Restic → Hetzner S3, DB dumps, restore procedures |
| [Image Updates](docs/operations/update-images.md) | Manual image update, crictl pre-pull for RWO PVCs |
| [Security Hardening Notes](docs/security-hardening-notes.md) | Local-only: ingress security status, open items (gitignored, not in this repo on GitHub) |

---

## Structure

```
apps/           Kubernetes manifests per service
  freshrss/     Namespace, PVC, Deployment, Service, Ingress
  pihole/       Namespace, Deployment, Service (LoadBalancer + Ingress)
  seafile/      Namespace, PVCs, StatefulSet (MariaDB), Deployments (Seafile, Redis)
  teslamate/    Namespace, PVCs, Deployments (Teslamate, PostgreSQL, Grafana)

docs/           Guides and architecture documentation

infrastructure/ Cluster infrastructure (Monitoring, Traefik config)
                → managed by Flux CD

clusters/       Flux CD configuration
  raspi/        Cluster entrypoint
```

---

## Migration Status

Migration from Docker Compose to k3s is complete. All services listed below run on k3s; the Docker Compose homelab (and its nginx/fail2ban edge proxy) has been fully decommissioned.

| Service | Notes |
|---|---|
| FreshRSS | Volume migrated |
| Pi-hole | DNS via LoadBalancer + Ingress |
| Seafile | Set up directly in k3s |
| Immich | Restic-restored, runs on the Agent-Node (`k3s-a1`) alongside the other workloads — not the Server-Node as originally planned, see [Immich Migration](docs/services/immich.md) |
| Paperless | DB + media volumes migrated, Google OIDC |
| Teslamate | DB restored from pg_dump |
| Home Assistant | `hostNetwork` + `nodeAffinity` for Zigbee dongle, runs on the Agent-Node |
| Vaultwarden | Concept only — Google SSO (OIDC fork), YubiKey 2FA — Kubernetes deployment not yet started |
