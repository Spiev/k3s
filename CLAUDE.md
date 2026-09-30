# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Private k3s (lightweight Kubernetes) infrastructure repository. Hardware: 2× Raspberry Pi 5 (8 GB RAM). Migration from the Docker-based homelab in `../docker-runtime` is complete — Docker Compose and its nginx/fail2ban edge proxy have been fully decommissioned.

## Architecture

- **OS**: Raspberry Pi OS Lite (64-bit, Trixie) — keeps native hardware tools (`raspi-config`, `vcgencmd`, `rpi-eeprom-update`)
- **Hardware**: 2× Raspberry Pi 5 (8 GB RAM) — Server-Node `k3s` (4 TB NVMe, control plane + Traefik only), Agent-Node `k3s-a1` (2 TB NVMe, all workloads incl. Immich — joined the cluster after the Docker migration completed)
- **k3s**: both nodes joined, Agent-Node runs the workloads
- **local-path-provisioner** (k3s built-in) for persistent storage — files stored directly on node filesystem
- **Traefik** (k3s built-in) as ingress controller — the sole internet-facing entry point (cert-manager is installed and `Ready` but not yet wired to any ingress; a manually-imported cert is in use, see `docs/security-hardening-notes.md`, local-only, for the open migration)
- **Flux CD** for GitOps (pull-based, bootstrapped from this repo)
- **SOPS + age** for encrypting secrets that can be committed to this public repo (built into Flux's kustomize-controller, no extra controller needed)

### Repository Structure

```
clusters/raspi/     ← Flux entrypoint for the cluster
apps/               ← per-service Kubernetes manifests (Deployments, PVCs, IngressRoutes, Secrets)
infrastructure/     ← shared infrastructure (cert-manager, Traefik config)
docs/               ← learning path and setup guides
```

## Services Migration Status

Current status is tracked in the [README — Migration Status](README.md#migration-status). All services have been migrated from `../docker-runtime`; that repo's Docker Compose stack is decommissioned.

## Conventions

- Commit messages: Conventional Commits (English)
- YAML indentation: 2 spaces
- All Kubernetes resources need `namespace` and `labels` set explicitly
- Service Namespaces must have `type: service` label — enables `kubectl get ns -l type=service` for bulk operations (e.g. shutdown)
- Secrets: always use SOPS (`sops --encrypt --in-place`), file suffix `*.sops.yaml`, never plain `Secret` objects in git
- Storage: `storageClassName: local-path` in all PVCs — files at `/var/lib/rancher/k3s/storage/<pvc-name>/`
- **No Kustomize** — single manifest file per service (e.g. `apps/freshrss/freshrss.yaml`), Ingress in separate `*-ingress.yaml` excluded via `.gitignore`; deploy with `kubectl apply -f apps/<service>/`
