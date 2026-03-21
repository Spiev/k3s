# k3s Homelab

Kubernetes-Infrastruktur auf einem Raspberry Pi 5 (8 GB RAM, 256 GB NVMe). Migration der bestehenden Docker-Services aus [docker-runtime](../docker-runtime).

**Hardware:** 2× Raspberry Pi 5 (8 GB RAM) — Server-Node 256 GB NVMe, Agent-Node 2 TB NVMe

**Stack:** k3s · Longhorn · Traefik · Flux CD · Sealed Secrets

---

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [Architektur-Übersicht](docs/00-architecture.md) | Gesamtbild, Netzwerkfluss, Komponenten — guter Einstieg |
| [Learning Path](docs/learning-path.md) | Lernpfad und Architekturentscheidungen |
| [01 — OS Setup](docs/01-os-setup.md) | Raspberry Pi OS auf NVMe, EEPROM, cgroups |
| [02 — k3s installieren](docs/02-k3s-install.md) | k3s mit Dual-Stack (IPv4+IPv6), kubectl, Grundkonzepte |
| [03 — Longhorn](docs/03-longhorn.md) | Persistenter Storage, Verschlüsselung, Backup-Strategie |
| [04a — FreshRSS](docs/04a-freshrss.md) | Migration: FreshRSS deployen |
| [04b — Pi-hole](docs/04b-pihole.md) | Migration: Pi-hole, DNS via LoadBalancer + Ingress |
| [04c — Seafile](docs/04c-seafile.md) | Migration: Seafile, Multi-Container, Secrets |
| [04d — Immich](docs/04d-immich.md) | Migration: Immich, Restic-Restore-Strategie (1.5 TB Library) |
| [06 — Monitoring](docs/06-monitoring.md) | kube-prometheus-stack, Grafana, Alertmanager |
| [09 — Backup & Restore](docs/09-backup-restore.md) | Cluster-Rebuild, Longhorn-Restore, kritische Secrets |
| [10 — Migration: unverschlüsselt → verschlüsselt](docs/10-migrate-to-encrypted.md) | Volume-Migration auf LUKS-verschlüsselte StorageClass |

---

## Struktur

```
apps/           Kubernetes-Manifeste je Service
  freshrss/     Namespace, PVC, Deployment, Service, Ingress
  seafile/      (in Planung)
  pi-hole/      (in Planung)

docs/           Anleitungen und Architektur-Dokumentation

infrastructure/ Cluster-Infrastruktur (Longhorn, Traefik-Config)
                → wird mit Flux CD eingerichtet

clusters/       Flux CD Konfiguration
  raspi/        Einstiegspunkt für den Cluster
```

---

## Migrationsstatus

| Service | Status | Anmerkung |
|---|---|---|
| FreshRSS | ✅ Migriert | Läuft auf k3s, Volume-Migration auf encrypted ausstehend |
| Pi-hole | In Planung | DNS via LoadBalancer, Admin-UI via Traefik |
| Seafile | Planung | Direkt in k3s neu aufsetzen |
| Immich | Offen | Restic-Restore-Strategie (kein Platz zum Kopieren) — erst nach Agent-Node-Join |
| Paperless | Offen | |
| Teslamate | Offen | |
| Home Assistant | Geplant (Agent-Node) | `hostNetwork` + `nodeAffinity` für Zigbee-Dongle |
