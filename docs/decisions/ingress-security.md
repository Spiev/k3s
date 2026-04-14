# Architecture Decision: CrowdSec instead of fail2ban for Ingress Security

**Date:** 2026-04-14
**Status:** Decided — implementation pending

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

4. **Scales to multi-node.** When the Agent-Node joins the cluster, CrowdSec's agent-bouncer architecture naturally covers both nodes without reconfiguration.

5. **Designed for containerised environments.** fail2ban was built for host-level log parsing. CrowdSec is cloud-native and has first-class Kubernetes support.

**Why fail2ban was sufficient in the Docker setup:**

nginx wrote access logs to the host filesystem, fail2ban ran on the host and read them — a natural fit for a Docker-compose stack. This architecture does not translate cleanly to k3s.

---

## Consequences

- CrowdSec runs as a Deployment in k3s (or DaemonSet for multi-node)
- The Traefik Bouncer is registered as a plugin in the Traefik Helm values / k3s config
- A `Middleware` resource is created and referenced in all IngressRoutes
- fail2ban is decommissioned on the Pi nodes once CrowdSec is active
- nginx (docker-runtime proxy) is decommissioned once all services are on k3s

---

## Implementation order

1. Migrate remaining Docker services (Paperless, Teslamate) to k3s
2. Set up CrowdSec + Traefik Bouncer
3. Verify protection is equivalent to existing nginx + fail2ban
4. Decommission nginx, fail2ban, docker-runtime proxy stack
5. Agent-Node joins → CrowdSec coverage extends automatically
