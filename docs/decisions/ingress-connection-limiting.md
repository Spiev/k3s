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

## Slowloris: covered by entry-point timeouts, not `inFlightReq`

The one legitimate scenario `limit_conn`/`inFlightReq` is sometimes used for is **Slowloris** — a client opening many connections and sending the request very slowly to exhaust the connection pool. `inFlightReq` is the wrong tool here (it caps concurrency, not slow connections) and would still hit the Immich false-positive above.

The correct control is **entry-point timeouts**. Two factors:

1. **Traefik (Go `net/http`) is inherently more Slowloris-resistant** than thread-pool servers (Apache): each connection is a cheap goroutine, so idle/slow connections do not exhaust a worker pool.
2. **`respondingTimeouts` bound the worst case.** Traefik's default `readTimeout` is `0` (unlimited) — a slow client could hold a connection open indefinitely. Both entry points (`web`, `websecure`) therefore set explicit timeouts in `infrastructure/traefik/traefik-config.yaml`:

   | Timeout | Value | Purpose |
   |---|---|---|
   | `readTimeout` | 300s | Max time to read the full request incl. body |
   | `writeTimeout` | 300s | Max time to write the response |
   | `idleTimeout` | 180s | Close idle keep-alive connections |

   `readTimeout` covers the **entire** request (including body), so it is sized to the largest legitimate slow upload (Seafile/Immich had no size limit and `client_body_timeout 300s` in nginx) rather than tighter — a lower value would break legitimate large/slow uploads. This bounds a Slowloris connection to 5 minutes instead of forever, with Go's connection model and CrowdSec (banning IPs that open many connections) as the real backstop.

### Migration note: total vs. inactivity timeout (check at the edge-flip)

⚠️ **Flip-check for when Traefik becomes the edge (replacing nginx).**

Traefik's `readTimeout`/`writeTimeout` are **total** durations for the whole request/response. nginx's equivalents (`client_body_timeout`, `proxy_read_timeout`) were **inactivity** timeouts — the clock reset on every chunk of data transferred.

- **While Traefik sits behind nginx (current state):** irrelevant. The slow client leg terminates at nginx; the nginx↔Traefik hop is fast LAN, so the 300s total is never approached.
- **Once Traefik is the edge:** a very large Seafile transfer over a slow line could exceed the 300s **total** limit even though it streamed fine under nginx's inactivity model. At the flip, **re-check the Seafile route timeouts** — raise the entry-point value, or set a per-route timeout via a dedicated `Middleware`/`ServersTransport` rather than loosening the global entry point.

Tracked alongside the other open edge-flip items: CrowdSec + Traefik bouncer, cert-manager ClusterIssuer, and the `trustedIPs`/`ipStrategy.depth` fix.

## Consequences

- No `inFlightReq` middlewares are created or referenced
- Abuse/DoS protection relies on CrowdSec (IP banning) and rate limiting (request throttling)
- Slowloris is bounded by entry-point `respondingTimeouts`, not connection limiting
- Pod resource limits in each service manifest remain the backstop against resource exhaustion
