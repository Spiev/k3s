# Immich Migration: Docker → k3s

Immich is the most complex migration candidate due to its data volume. This guide describes the strategy and concrete steps.

---

## Starting point & constraints

Immich currently runs on the old Raspi (Docker, 2 TB NVMe) with a library of ~1.5 TB. In the k3s target state it moves to the **Server-Node** — the only storage-heavy service on that node, alongside the Control Plane. The old Raspi is reinstalled as the k3s Agent-Node; Docker and k3s cannot run in parallel.

**The problem:**
```
Old Raspi NVMe (1.8T total):  ~1.6T used, ~200G free
  └── Immich library:  ~1.5 TB
  └── all other services: ~12 GB
External SSD:         ~393G free  (not enough for 1.5T)
```

A classic in-place migration pod (copy old volume → new PVC on the same disk) is not viable — there is ~1.5 TB of free space missing on the old 2 TB disk. Instead the library is restored from the Restic backup onto the fresh 4 TB Server-Node, which has ample free space.

---

## Strategy: Restic restore onto the Server-Node

The Server-Node runs on a fresh 4 TB NVMe (~3.6 TB free) — ample room for the local-path PVC + restore of the Immich library from the Restic backup. The old Raspi's disk is never the restore target.

The Restic backup contains:
- Immich library (photos/videos)
- PostgreSQL dump (via Immich's built-in backup worker, stored in the library directory)

```
Restic repo (external SSD / Hetzner S3)
        │
        │  restic restore
        ▼
Server-Node (4 TB NVMe)
  └── local-path PVC (1.6T+, on NVMe)
        │
        ▼
Immich deployment in k3s (nodeSelector → Server-Node)
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

### Phase 2 — Free the old Raspi & prepare the Server-Node

1. The old Raspi (Docker Immich instance) is reinstalled as the k3s Agent-Node — this stops the Docker Immich and frees the 2 TB disk. Immich's data lives only in the Restic backup from here on.
2. The Server-Node must already run on its new NVMe with ~3.6 TB free (see the migration runbook for the 256 GB → 4 TB disk swap).
3. Flash / join steps for the old Raspi: enable cgroups, disable swap (→ [os-setup.md](../platform/os-setup.md)), install the k3s agent and join the cluster (→ [k3s-install](../platform/k3s-install.md)).

### Phase 3 — Create local-path PVC on the Server-Node

The PVC is automatically created on the node where the pod runs. Pin the node via `nodeSelector`:

```yaml
# In apps/immich/immich.yaml
# Deployment with nodeSelector pointing to the Server-Node
# PVC size: at least current library size + buffer (e.g. 1800Gi)
```

### Phase 4 — Restore from Restic

Deploy a temporary restore pod **on the Server-Node** that mounts the PVC + the Restic repo source:

```yaml
# restore-pod.yaml (deleted after restore, not committed)
volumes:
  - name: immich-data
    persistentVolumeClaim:
      claimName: immich-library
  - name: backup-ssd
    hostPath:
      path: /mnt/sda1   # external SSD carrying the Restic repo, attached to the Server-Node
```

> The external SSD holding the Restic repo is currently attached to the old Raspi. For the restore, make the repo reachable from the Server-Node — either physically move the SSD, or restore from the Hetzner S3 copy instead (larger download, no re-plugging).

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

- The Server-Node must already run on its new NVMe with enough free space (256 GB → 4 TB disk swap done)
- The old Raspi's Docker Immich must be stopped (its reinstall as Agent-Node frees the 2 TB disk); Immich data then lives only in the Restic backup
- The Restic repo must be reachable from the Server-Node (external SSD moved, or restore from Hetzner S3)
- SOPS + age must be set up (→ Phase 6 in learning-path)
- Flux CD optional, but recommended before Immich is migrated
