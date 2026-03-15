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
| [02 — k3s installieren](docs/02-k3s-install.md) | k3s, kubectl, Grundkonzepte |
| [03 — Longhorn](docs/03-longhorn.md) | Persistenter Storage, Backup-Strategie |
| [04 — FreshRSS](docs/04-freshrss.md) | Erster Service: deployen & migrieren |
| [05 — Seafile](docs/05-seafile.md) | Zweiter Service: Planung & Architektur |

---

## Struktur

```
apps/           Kubernetes-Manifeste je Service
  freshrss/     Namespace, PVC, Deployment, Service, Ingress
  seafile/      (in Planung)

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
| FreshRSS | ✅ Migriert | Läuft auf k3s |
| Seafile | Planung | Direkt in k3s neu aufsetzen |
| Immich | Offen | Hohe Komplexität (ML, PostgreSQL) |
| Paperless | Offen | |
| Teslamate | Offen | |
| Pi-hole | Offen | |
| Home Assistant | Geplant (Agent-Node) | `hostNetwork` + `nodeAffinity` für Zigbee-Dongle |
