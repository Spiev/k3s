# Architekturentscheidung: local-path statt Longhorn

**Datum:** 2026-04-06
**Status:** Beschlossen

---

## Kontext

Beim initialen Setup wurde Longhorn als Storage-Backend gewählt. Nach Betrieb mit zwei laufenden Services (FreshRSS, Pi-hole) wurde die Entscheidung revisited.

**Rahmenbedingungen:**

- Zwei Raspberry Pi 5 Nodes mit unterschiedlichen NVMe-Größen (256 GB / 2 TB)
- Services müssen sowieso explizit auf Nodes gepinnt werden — entweder wegen Hardware (Zigbee-Dongle, 2 TB für Immich) oder Speicherplatz
- Der Agent-Node ist zum Entscheidungszeitpunkt noch nicht im Cluster
- DNS-Redundanz wird über zwei Pi-hole-Instanzen mit MetalLB-VIP gelöst, nicht über Storage-Replikation

---

## Entscheidung

**local-path-provisioner** (k3s built-in) statt Longhorn.

---

## Bewertung der Alternativen

| Option | Replikation | ARM64 | Komplexität | Bewertung |
|---|---|---|---|---|
| `local-path` (k3s built-in) | ❌ | ✅ | minimal | ✅ Gewählt |
| Longhorn | ✅ | ✅ | mittel | Overkill — siehe unten |
| Rook/Ceph | ✅ | ✅ | sehr hoch | Overkill für 2 Nodes |
| NFS | ❌ (SPOF) | ✅ | niedrig | Nein |

---

## Begründung

**Warum Longhorn hier keinen Mehrwert bringt:**

1. **Services sind sowieso gepinnt.** Jeder Service ist aus Hardware- oder Speicherplatzgründen fest einem Node zugeordnet. Longhorn's Stärke (Pods können zwischen Nodes wandern, Daten folgen automatisch) ist hier irrelevant.

2. **Backup ist einfacher ohne Longhorn.** `local-path` speichert Dateien direkt auf dem Filesystem (`/var/lib/rancher/k3s/storage/<pvc-name>/`) — lesbar wie Docker-Volumes. Longhorn speichert in eigenem Block-Device-Format, das nicht direkt zugänglich ist. Mit `local-path` kann Restic Dateien direkt sichern.

3. **Kein automatisches Failover nötig.** Für ein 2-Node-Homelab ist manuelle Migration bei einem Node-Ausfall akzeptabel. Automatisches Failover lohnt sich erst mit echter HA-Anforderung.

4. **Longhorn-Komplexität ohne Gegenwert:** iSCSI-Treiber, eigener Namespace mit ~30 Pods, LUKS-Verschlüsselung über eigene Crypto Secrets, bug-behaftete `fromBackup`-Integration — alles Overhead ohne konkreten Nutzen im Single-Node-Betrieb.

**Wann Longhorn sinnvoll wäre:**
- Automatisches Pod-Failover zwischen Nodes ist Pflicht
- Beide Nodes laufen produktiv im Cluster
- Services dürfen sich dynamisch zwischen Nodes bewegen

Wenn der Agent-Node beitritt und diese Anforderungen entstehen, kann Longhorn nachträglich eingeführt werden.

---

## Konsequenzen

- PVCs erhalten automatisch `nodeAffinity` auf den Node wo sie erstellt wurden → technisch erzwingt, was ohnehin geplant ist
- "Verschieben" eines Services bedeutet: PVC löschen, Daten kopieren, neu anlegen — manuelle Operation
- Backup: Restic sichert Dateien direkt aus dem Filesystem, kein Snapshot-Mechanismus nötig
- DNS-Redundanz: Zwei Pi-hole-Instanzen (je eine pro Node) hinter MetalLB-VIP — Storage-Backend ist dabei irrelevant
- **Migration von Longhorn zu local-path:** Für laufende Services (FreshRSS, Pi-hole) muss die Datenmigration einmalig durchgeführt werden — Migrations-Pod mountet altes Longhorn-PVC und neues local-path-PVC, kopiert Daten, anschließend Longhorn deinstallieren. Details: [`docs/operations/longhorn-migration.md`](../operations/longhorn-migration.md)
