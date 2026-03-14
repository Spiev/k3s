# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Private k3s (lightweight Kubernetes) infrastructure repository. Target hardware: Raspberry Pi 5 (8 GB RAM, 256 GB NVMe). Companion to the Docker-based homelab in `../docker-runtime`.

## Architecture

- **OS**: Raspberry Pi OS Lite (64-bit, Bookworm) — keeps native hardware tools (`raspi-config`, `vcgencmd`, `rpi-eeprom-update`)
- **Hardware**: 2× Raspberry Pi 5 (8 GB RAM) — Server-Node 256 GB NVMe, Agent-Node 2 TB NVMe (currently Docker, joins k3s after full migration)
- **k3s** single-node to start; Agent-Node joins when all Docker services are migrated
- **Longhorn** for hyperconverged persistent storage (replicates across nodes)
- **Traefik** (k3s built-in) as ingress controller with cert-manager for Let's Encrypt
- **Flux CD** for GitOps (pull-based, bootstrapped from this repo)
- **Sealed Secrets** for encrypting secrets that can be committed to this public repo

### Repository Structure (target)

```
clusters/raspi/     ← Flux entrypoint for the cluster
apps/               ← per-service Kubernetes manifests (Deployments, PVCs, IngressRoutes, Secrets)
infrastructure/     ← shared infrastructure (Longhorn, cert-manager, Traefik config)
docs/               ← learning path and setup guides
```

## Services Being Migrated

Coming from `../docker-runtime`. Migration order by complexity:
1. **FreshRSS** — single volume (`./config`), no DB cluster, first candidate
2. **Seafile** — 2 containers (`seafile-mc` + MariaDB), 2 PVCs, Secrets; sync-based so file blobs survive on clients even if cluster is down (DB metadata/history does not)

## Conventions

- Commit messages: Conventional Commits (English)
- YAML indentation: 2 spaces
- All Kubernetes resources need `namespace` and `labels` set explicitly
- Secrets: always use Sealed Secrets (`kubeseal`), never plain `Secret` objects in git
- Longhorn StorageClass: `longhorn` (set as default), `numberOfReplicas: "1"` until second node joins, then `"2"`
