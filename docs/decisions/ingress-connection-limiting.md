# Architecture Decision: No per-IP connection limiting (inFlightReq) in Traefik

**Date:** 2026-05-10
**Status:** Decided

---

## Context

nginx enforced `limit_conn` per service (10–20 concurrent connections per IP) to protect against connection exhaustion on fixed hardware. Traefik's equivalent is the `inFlightReq` middleware, which limits concurrent in-flight requests per IP.

**Constraints:**

- Single-node cluster (pi2, Raspberry Pi 5) — no auto-scaling
- CrowdSec + rate limiting are part of the middleware stack (see `ingress-security.md`)
- Immich gallery view generates a high number of parallel requests from a single client IP under normal use

---

## Decision

**Do not use `inFlightReq`** in any IngressRoute middleware chain.

---

## Evaluation of Alternatives

| Option | Protects against | Downside | Assessment |
|---|---|---|---|
| **No `inFlightReq`** | — | No per-IP concurrency cap | ✅ Chosen |
| `inFlightReq` per service | Connection exhaustion from single IP | Breaks legitimate high-concurrency clients (Immich gallery); caused service disruptions in practice | ❌ Rejected |

---

## Rationale

1. **Cloud-native philosophy.** In Kubernetes, the response to overload is horizontal scaling, not client throttling. Pod resource limits (CPU/memory) prevent a single service from overloading the node — the correct control point.

2. **CrowdSec covers the abuse scenario.** An attacker holding many connections from a single IP is a known scanner/DoS pattern. CrowdSec detects and bans it. `inFlightReq` would be a redundant second layer for this case.

3. **Rate limiting covers the flood scenario.** `rate-limit-general` (20 req/s) and `rate-limit-login` (5 req/min) throttle high-volume traffic before connection exhaustion can occur.

4. **Causes false positives under normal use.** Immich's gallery view loads thumbnails in parallel — a single user session can generate 50–200 concurrent requests. `inFlightReq` limits of 10–20 trigger 503 errors under normal gallery browsing. This was confirmed in practice.

5. **Operational complexity without security gain.** Tuning per-service limits to avoid false positives while still providing protection is difficult to get right and creates ongoing maintenance burden.

---

## Consequences

- No `inFlightReq` middlewares are created or referenced
- Abuse/DoS protection relies on CrowdSec (IP banning) and rate limiting (request throttling)
- Pod resource limits in each service manifest remain the backstop against resource exhaustion
