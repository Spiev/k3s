# Immich Migration: Docker → k3s

Immich is the most complex migration candidate due to its data volume. This guide describes the strategy and concrete steps.

---

## Starting point & constraints

Immich runs on the Agent-Node (2 TB NVMe) with a library of ~1.5 TB. The Agent-Node must be reinstalled for the k3s join — Docker and k3s cannot run in parallel.

**The problem:**
```
NVMe (1.8T total):  ~1.6T used, ~200G free
  └── Immich library:  ~1.5 TB
  └── all other services: ~12 GB
External SSD:         ~393G free  (not enough for 1.5T)
```

A classic migration pod (copy old volume → new PVC) is not viable — there is ~1.5 TB of free space missing on the same disk.

---

## Strategy: Restic restore after reinstall

The Agent-Node is reinstalled (NVMe is wiped). Afterwards ~1.8 TB are free — enough for the local-path PVC + restore of the Immich library from the Restic backup.

The Restic backup contains:
- Immich library (photos/videos)
- PostgreSQL dump (via Immich's built-in backup worker, stored in the library directory)

```
External SSD (Restic repo)
        │
        │  restic restore
        ▼
Freshly installed Agent-Node
  └── local-path PVC (1.6T+, on NVMe)
        │
        ▼
Immich deployment in k3s
```

---

## Order of operations

### Phase 1 — Prerequisites

1. **Migrate all other Docker services first:** Pi-hole, Teslamate, Home Assistant, Paperless (together ~12 GB — not critical for storage)
2. **Ensure S3 off-site backup is current:** Restic already runs locally to external SSD. Before migration, verify the off-site backup is also up to date → two independent copies
3. **Verify backup integrity:**
   ```bash
   restic -r <repo-path> check --read-data
   ```
   `--read-data` is important — without this flag Restic only checks metadata, not the actual data. With ~1.5 TB this takes a while.
4. **Trigger one final backup manually** before the wipe

### Phase 2 — Reinstall Agent-Node

1. Flash Raspberry Pi OS Lite (64-bit, Bookworm) to NVMe
2. Enable cgroups, disable swap (→ [os-setup.md](../platform/os-setup.md))
3. Install k3s agent and join the cluster (→ [k3s-install](../platform/k3s-install.md))

### Phase 3 — Create local-path PVC

The PVC is automatically created on the node where the pod runs. Pin the node via `nodeSelector`:

```yaml
# In apps/immich/immich.yaml
# Deployment with nodeSelector pointing to Agent-Node
# PVC size: at least current library size + buffer (e.g. 1800Gi)
```

### Phase 4 — Restore from Restic

Deploy a temporary restore pod that mounts the PVC + external SSD:

```yaml
# restore-pod.yaml (deleted after restore, not committed)
volumes:
  - name: immich-data
    persistentVolumeClaim:
      claimName: immich-library
  - name: backup-ssd
    hostPath:
      path: /mnt/sda1   # external SSD on Agent-Node
```

In the pod:
```bash
restic -r /backup/restic-repo restore latest \
  --target /data \
  --include '**/immich/library'
```

### Phase 5 — Deploy Immich & verify

1. Delete the restore pod
2. Deploy Immich (server, machine-learning, redis, postgres)
3. In the Immich UI: Admin → Jobs → run "Library Scan"
4. Spot-check: a few albums, faces, search
5. Activate Traefik IngressRoute, switch DNS/nginx
6. The external SSD can continue to be used as a pure backup target

---

## Stack overview (4 containers)

| Container | Image | Purpose |
|---|---|---|
| immich-server | `ghcr.io/immich-app/immich-server` | API + web UI |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning` | Face recognition, CLIP search |
| redis | `docker.io/valkey/valkey:8-bookworm` | Cache & queue |
| postgres | `ghcr.io/immich-app/postgres:16-vectorchord...` | DB with pgvectors extension |

> The Postgres image is Immich-specific (includes VectorChord/pgvectors) — do not use a standard PostgreSQL image.

**Volumes:**
- `immich-library` PVC → `/usr/src/app/upload` in immich-server
- `immich-postgres` PVC → `/var/lib/postgresql/data`
- `model-cache` PVC → `/cache` in the machine-learning container

**Secrets (SOPS):**
- `DB_PASSWORD`
- `DB_USERNAME`, `DB_DATABASE_NAME`

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Restic restore fails | `restic check --read-data` beforehand + S3 off-site as second copy |
| Incomplete restore | Test-restore of a folder before the wipe |
| Postgres dump missing/outdated | Check Immich backup job in UI: Admin → Jobs → "Database Backup" |
| PVC too small | Measure current usage before migration: `du -sh ~/docker/immich/library` |

---

## Dependencies

- All other Docker services must be migrated first (Agent-Node must be free for reinstall)
- SOPS + age must be set up (→ Phase 6 in learning-path)
- Flux CD optional, but recommended before Immich is migrated
