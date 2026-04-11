# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Private k3s (lightweight Kubernetes) infrastructure repository. Target hardware: Raspberry Pi 5 (8 GB RAM, 256 GB NVMe). Companion to the Docker-based homelab in `../docker-runtime`.

## Architecture

- **OS**: Raspberry Pi OS Lite (64-bit, Bookworm) — keeps native hardware tools (`raspi-config`, `vcgencmd`, `rpi-eeprom-update`)
- **Hardware**: 2× Raspberry Pi 5 (8 GB RAM) — Server-Node 256 GB NVMe, Agent-Node 2 TB NVMe (currently Docker, joins k3s after full migration)
- **k3s** single-node to start; Agent-Node joins when all Docker services are migrated
- **local-path-provisioner** (k3s built-in) for persistent storage — files stored directly on node filesystem
- **Traefik** (k3s built-in) as ingress controller with cert-manager for Let's Encrypt
- **Flux CD** for GitOps (pull-based, bootstrapped from this repo)
- **SOPS + age** for encrypting secrets that can be committed to this public repo (built into Flux's kustomize-controller, no extra controller needed)

### Repository Structure (target)

```
clusters/raspi/     ← Flux entrypoint for the cluster
apps/               ← per-service Kubernetes manifests (Deployments, PVCs, IngressRoutes, Secrets)
infrastructure/     ← shared infrastructure (cert-manager, Traefik config)
docs/               ← learning path and setup guides
```

## Services Migration Status

Current status is tracked in the [README — Migration Status](README.md#migration-status). Services are migrated from `../docker-runtime`.

## Conventions

- Commit messages: Conventional Commits (English)
- YAML indentation: 2 spaces
- All Kubernetes resources need `namespace` and `labels` set explicitly
- Service Namespaces must have `type: service` label — enables `kubectl get ns -l type=service` for bulk operations (e.g. shutdown)
- Secrets: always use SOPS (`sops --encrypt --in-place`), file suffix `*.sops.yaml`, never plain `Secret` objects in git
- Storage: `storageClassName: local-path` in all PVCs — files at `/var/lib/rancher/k3s/storage/<pvc-name>/`
- **No Kustomize** — single manifest file per service (e.g. `apps/freshrss/freshrss.yaml`), Ingress in separate `*-ingress.yaml` excluded via `.gitignore`; deploy with `kubectl apply -f apps/<service>/`
