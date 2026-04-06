# Architecture Decision: local-path instead of Longhorn

**Date:** 2026-04-06
**Status:** Decided

---

## Context

Longhorn was chosen as the storage backend during initial setup. After running two services (FreshRSS, Pi-hole), the decision was revisited.

**Constraints:**

- Two Raspberry Pi 5 nodes with different NVMe sizes (256 GB / 2 TB)
- Services must be explicitly pinned to nodes anyway — either due to hardware (Zigbee dongle, 2 TB for Immich) or storage capacity
- The Agent-Node is not yet part of the cluster at the time of this decision
- DNS redundancy is handled via two Pi-hole instances with a MetalLB VIP, not via storage replication

---

## Decision

**local-path-provisioner** (k3s built-in) instead of Longhorn.

---

## Evaluation of Alternatives

| Option | Replication | ARM64 | Complexity | Assessment |
|---|---|---|---|---|
| `local-path` (k3s built-in) | ❌ | ✅ | minimal | ✅ Chosen |
| Longhorn | ✅ | ✅ | medium | Overkill — see below |
| Rook/Ceph | ✅ | ✅ | very high | Overkill for 2 nodes |
| NFS | ❌ (SPOF) | ✅ | low | No |

---

## Rationale

**Why Longhorn adds no value here:**

1. **Services are pinned anyway.** Every service is assigned to a fixed node due to hardware or storage constraints. Longhorn's strength (pods can migrate between nodes, data follows automatically) is irrelevant here.

2. **Backup is simpler without Longhorn.** `local-path` stores files directly on the filesystem (`/var/lib/rancher/k3s/storage/<pvc-name>/`) — readable like Docker volumes. Longhorn stores data in its own block-device format, which is not directly accessible. With `local-path`, Restic can back up files directly.

3. **No automatic failover needed.** Manual migration on node failure is acceptable for a 2-node homelab. Automatic failover only pays off with real HA requirements.

4. **Longhorn complexity without benefit:** iSCSI driver, a dedicated namespace with ~30 pods, LUKS encryption via custom crypto secrets, buggy `fromBackup` integration — all overhead with no concrete benefit in single-node operation.

**When Longhorn would make sense:**
- Automatic pod failover between nodes is a hard requirement
- Both nodes are running productively in the cluster
- Services are allowed to move dynamically between nodes

If the Agent-Node joins and these requirements emerge, Longhorn can be introduced later.

---

## Consequences

- PVCs automatically receive `nodeAffinity` for the node on which they were created → technically enforces what was already planned
- "Moving" a service means: delete PVC, copy data, recreate — a manual operation
- Backup: Restic backs up files directly from the filesystem, no snapshot mechanism required
- DNS redundancy: two Pi-hole instances (one per node) behind a MetalLB VIP — storage backend is irrelevant for this
- **Migration from Longhorn to local-path:** For running services (FreshRSS, Pi-hole) a one-time data migration is required — a migration pod mounts the old Longhorn PVC and the new local-path PVC, copies the data, then Longhorn is uninstalled. Details: [`docs/operations/longhorn-migration.md`](../operations/longhorn-migration.md)
