# Architecture Decision: Collabora Online instead of OnlyOffice for Online Office Editing

**Date:** 2026-07-11
**Status:** Decided — implementation pending

---

## Context

Seafile is migrated and running on k3s. To edit office documents (`.odt`, `.docx`, `.xlsx`, `.pptx`) directly in the browser — without downloading, editing locally, and re-uploading — Seafile needs an integrated online office server. Seafile documents three integration paths: Collabora Online, OnlyOffice, and Office Online Server (Microsoft, Pro only).

Both Collabora and OnlyOffice are **self-hosted** — the file never leaves the cluster. "Online" refers to browser-based editing, not a cloud service. Files are exchanged server-to-server between the Seafile pod and the office pod; the browser only receives rendered output.

**Constraints:**

- Target node is a Raspberry Pi 5 (8 GB RAM), ARM64 — the office server competes for RAM with the rest of the cluster
- Home usage: typically 1–3 concurrent editors, not an organisation
- Data must stay self-hosted — no document upload to any third-party service
- The primary desktop office suite in daily use is **LibreOffice**
- The Agent-Node (2 TB) is not yet in the cluster; placement should stay flexible

---

## Decision

**Collabora Online (CODE — Collabora Online Development Edition)** as the online office server, integrated into Seafile via the WOPI protocol.

---

## Evaluation of Alternatives

| Option | ARM64 | Idle RAM | Min. RAM | Engine | Assessment |
|---|---|---|---|---|---|
| **Collabora Online (CODE)** | ✅ official | ~0.3–0.7 GB | ~2 GB | LibreOffice core | ✅ Chosen |
| OnlyOffice Document Server | ✅ (v7.1+) | ~1.5–2 GB | 4 GB + 2 GB swap | own C++/Node stack | Too heavy for 8 GB alongside the rest |
| Office Online Server | ✅ | high | high | Microsoft | Pro edition only — excluded |
| No online office | — | — | — | — | Download / edit / re-upload — the status quo we want to remove |

---

## Rationale

**Why Collabora over OnlyOffice — the RAM/architecture split:**

1. **Collabora reuses a lean, mature engine with a cheap sharing model.** At its core it is headless LibreOffice (`LibreOfficeKit`). A master process forks one kit process per open document via `fork()` with copy-on-write — the read-only LibreOffice core is loaded once and shared across all document processes. Baseline RAM is small; cost scales per *active document*.

2. **OnlyOffice pays a large fixed tax.** Its Document Server bundles a whole microservice stack in one container — nginx, several Node.js services, PostgreSQL, RabbitMQ, Redis, plus the C++ conversion core. These run permanently, even with zero open documents, which is why the official floor is 4 GB RAM + 2 GB swap. That architecture scales *flatter* for many simultaneous editors — a benefit we would never use at 1–3 users, while paying its cost every hour of the day.

3. **Format consistency with the desktop.** Daily editing already happens in LibreOffice. Collabora is the same engine, so a document opened on the laptop and continued in the browser renders identically — no layout/font drift, no conversion surprises on round-trips. OnlyOffice uses a different engine and can interpret complex documents slightly differently.

4. **Both are self-hosted and ARM64-native**, so neither the "data stays local" nor the architecture constraint decides between them — RAM and engine consistency do.

**Where OnlyOffice would win:** highest-fidelity rendering of complex Microsoft Office formats (`.docx`/`.xlsx`/`.pptx`). For an ODF + LibreOffice workflow this advantage is marginal.

---

## How the integration works (WOPI)

Seafile is the **WOPI host** (holds the file), Collabora is the **WOPI client** (edits it):

```
Browser                     Seafile (seafile-mc)             Collabora (code)
   │  1. click doc.odt            │                                 │
   ├─────────────────────────────►│  generates WOPI URL + JWT       │
   │  2. iframe loads editor ◄────┤                                 │
   ├──────────────────────────────┼────────────────────────────────►│
   │                              │◄── 3. CheckFileInfo / GetFile ──┤
   │                              │─── file content ───────────────►│  LibreOfficeKit
   │  4. tiles (bitmaps) + input ◄┼─────── WebSocket ───────────────┤  renders
   │  5. save                     │◄── PutFile (writes back) ───────┤
```

- Steps 3 and 5 are **server-to-server inside the cluster** (`collabora.seafile.svc` ↔ `seafile.seafile.svc`). The file goes from the Seafile pod straight into the Collabora pod and back to its local-path volume — never to a third party.
- The browser only ever receives rendered tiles, never the raw file transfer.
- Requests are authenticated with a shared **JWT secret** signed by Seahub; Collabora rejects anything unsigned.
- The only external dependency is pulling the `collabora/code` image; after that it runs fully offline in the cluster.

---

## Consequences

- Collabora runs as a **new Deployment + Service** in the `seafile` namespace.
- **Stateless** — no PVC, no database, no local volume. It fetches files on demand and forgets them.
- A **shared JWT secret** (SOPS-encrypted) is added to the Seafile secrets and referenced by both Collabora and the Seahub config.
- Collabora needs its **own Ingress** — it must be reachable from the browser over HTTPS (the editor iframe loads from it directly).
- `seahub_settings.py` is patched to enable the Collabora/WOPI integration (via the existing `patch-seahub-settings` init container pattern).
- **Resource `limits` should be set** so a runaway rendering session cannot starve the node.
- **Placement stays flexible.** Because Collabora is stateless, it can be scheduled on any node and freely rescheduled — no `nodeAffinity` pinning like local-path services. If a third Pi joins later, offloading is a one-line change: label the node (`kubectl label node <pi> role=office`) and add a `nodeSelector` to the Deployment; Flux reschedules it with zero data migration. Cross-node traffic (Seafile ↔ Collabora) is transparent via the ClusterIP service, and browser reachability is independent of the node — placement is purely a resource decision.

---

## Next: [Seafile](../services/seafile.md)
