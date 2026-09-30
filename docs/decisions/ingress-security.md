# Architecture Decision: CrowdSec instead of fail2ban for Ingress Security

**Date:** 2026-04-14
**Status:** Decided — CrowdSec implementation still pending

**Update (2026-09-30):** A related, narrower gap was closed ahead of
CrowdSec: LAN-only services (Pi-hole web UI, TeslaMate, TeslaMate-Grafana)
are now protected by a `lan-only` Traefik Middleware (`ipAllowList`
restricted to private source ranges), since the Fritzbox forwards all of
port 80 to Traefik, which previously routed purely by the client-controlled
Host header. A `redirect-https` catch-all was added alongside it. Verified
externally — spoofed Host headers from a public IP now get `403`. This does
not replace CrowdSec: it blocks host-header spoofing to LAN-only apps, not
brute-force/scanner traffic against public-facing services, which remains
unprotected until CrowdSec lands.

---

## Context

The Docker-based homelab used nginx as a reverse proxy with fail2ban for brute-force and scanner protection. As services migrate to k3s, Traefik replaces nginx as the ingress controller. A security layer equivalent to fail2ban is required for the pure k3s setup.

**Constraints:**

- Traefik (k3s built-in) is the single ingress point for all services
- All public-facing services require protection against brute-force, credential stuffing, and scanner traffic
- The solution should integrate natively with Traefik rather than relying on log-file parsing
- ARM64 (Raspberry Pi 5) support required

---

## Decision

**CrowdSec** as the security engine, with the **Traefik Bouncer** as a native Middleware.

---

## Evaluation of Alternatives

| Option | Integration | ARM64 | Blocks before hit | Threat Intelligence | Assessment |
|---|---|---|---|---|---|
| **CrowdSec + Traefik Bouncer** | Native Middleware | ✅ | ✅ | ✅ Community hub | ✅ Chosen |
| fail2ban on node | Log parsing | ✅ | ❌ (after the fact) | ❌ | Workable but hybrid |
| Traefik Middlewares only | Native | ✅ | ✅ (rate limit only) | ❌ | No banning, just throttling |
| Authelia / OAuth2-Proxy | Native | ✅ | ✅ | ❌ | Auth layer, not security scanner |

---

## Rationale

**Why CrowdSec over fail2ban-on-node:**

1. **Blocks before the request reaches the service.** The Traefik Bouncer acts as a Middleware — banned IPs are rejected at the ingress layer, not after the log has been written and parsed.

2. **No filesystem coupling.** fail2ban requires Traefik to write access logs to a file on the node, and fail2ban to read that file. CrowdSec integrates via the Traefik plugin API — no log paths to maintain.

3. **Community Threat Intelligence.** The CrowdSec Hub provides community-curated scenarios (SSH brute-force, web scanners, credential stuffing). Known-bad IPs from the community blocklist are blocked before a single request is seen locally.

4. **Scales to multi-node.** When a second node joins the cluster, CrowdSec's agent-bouncer architecture naturally covers both nodes without reconfiguration.

5. **Designed for containerised environments.** fail2ban was built for host-level log parsing. CrowdSec is cloud-native and has first-class Kubernetes support.

**Why fail2ban was sufficient in the Docker setup:**

nginx wrote access logs to the host filesystem, fail2ban ran on the host and read them — a natural fit for a Docker Compose stack. This architecture does not translate cleanly to k3s.

---

## Consequences

- CrowdSec runs as a Deployment in k3s (or DaemonSet for multi-node)
- The Traefik Bouncer is registered as a plugin in the Traefik Helm values / k3s config
- A `Middleware` resource is created and referenced in all IngressRoutes
- nginx and fail2ban (docker-runtime proxy) have already been decommissioned along with the rest of the Docker Compose homelab — this happened independently of CrowdSec's implementation status, and is not blocked on it. Until CrowdSec lands, distributed brute-force/scanner traffic across many source IPs has no ingress-layer mitigation (per-IP rate-limit middlewares still apply, see `infrastructure/traefik/traefik-middlewares.yaml`).
- Some application-level auth failures are not detectable at the HTTP proxy layer (HTTP 2xx response regardless of auth outcome). For affected services, application-native brute-force protection and rate limiting at the ingress layer serve as mitigations until a service-specific log parser is available in CrowdSec.
