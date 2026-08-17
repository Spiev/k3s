# Architecture Decision: Collabora Online instead of OnlyOffice for Online Office Editing

**Date:** 2026-07-11
**Status:** Implemented (2026-08-17) — see [Seafile: Collabora / Online-Office-Editing](../services/seafile.md#collabora--online-office-editing)

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

- Steps 3 and 5 stay within our own infrastructure, but not purely via ClusterIP as originally assumed: Collabora calls back on the `WOPISrc` URL it was given when the iframe loaded, which is the **public hostname** (`https://<hostname>/api2/wopi/files/...`), not `seafile.seafile.svc` directly. That request round-trips out through the nginx/Traefik layer and back in — still entirely inside our own infra (never a third party), just not the internal-only hop the diagram implies. (`OFFICE_WEB_APP_BASE_URL` — the URL Seahub uses to reach *Collabora* — has the same public-hostname requirement; see [Seafile docs](../services/seafile.md#collabora--online-office-editing) for why the internal `collabora.seafile.svc` name doesn't work there either.)
- The browser only ever receives rendered tiles, never the raw file transfer.
- Requests are authenticated with a short-lived **WOPI access token** that Seahub issues per edit session (not a static shared secret — see Consequences below).
- The only external dependency is pulling the `collabora/code` image; after that it runs fully offline in the cluster.

---

## Consequences

- Collabora runs as a **new Deployment + Service** in the `seafile` namespace.
- **Stateless** — no PVC, no database, no local volume. It fetches files on demand and forgets them.
- **No shared JWT secret is needed** (revised after implementation research — the original assumption below was wrong). Seahub issues a short-lived WOPI access token per edit session automatically; Collabora authenticates the request source via a WOPI host allowlist (`storage.wopi.host`, set via `extra_params`) instead of a static secret. The existing `JWT_PRIVATE_KEY` in the Seafile secrets is Seafile's internal Seahub↔fileserver auth and is unrelated to Collabora.
- **No separate Ingress or hostname.** Collabora natively serves its own routes under the top-level paths `/browser`, `/cool`, `/hosting` — these are added as extra path rules to the *existing* Seafile Ingress (same host), avoiding a second DNS name and TLS certificate entirely. Traefik path-routes to the `seafile` vs. `collabora` Service under one hostname; nothing changes on the external nginx reverse-proxy layer (`docker-runtime` repo), which already forwards the whole domain (any path) plus WebSocket upgrade headers.
- `seahub_settings.py` is patched to enable the Collabora/WOPI integration (via the existing `patch-seahub-settings` init container pattern).
- **Resource `limits` should be set** so a runaway rendering session cannot starve the node.
- **Placement stays flexible.** Because Collabora is stateless, it can be scheduled on any node and freely rescheduled — no `nodeAffinity` pinning like local-path services. If a third Pi joins later, offloading is a one-line change: label the node (`kubectl label node <pi> role=office`) and add a `nodeSelector` to the Deployment; Flux reschedules it with zero data migration. Cross-node traffic (Seafile ↔ Collabora) is transparent via the ClusterIP service, and browser reachability is independent of the node — placement is purely a resource decision.

---

## Next: [Seafile](../services/seafile.md)
