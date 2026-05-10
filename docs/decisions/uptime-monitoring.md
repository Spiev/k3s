# Architecture Decision: SaaS Uptime Monitoring (UptimeRobot)

**Date:** 2026-04-14
**Status:** Decided — implemented

---

## Context

Public-facing services require external uptime monitoring — a check that runs outside the homelab and alerts when a service is unreachable from the internet. An internal health check cannot detect DNS failures, router outages, or cert expiry from the user's perspective.

**Constraints:**

- Monitor must run outside the homelab network (external perspective)
- Alert delivery must not depend on the homelab being up (i.e., not via self-hosted notification service)
- Minimal operational overhead — no additional service to host, patch, or migrate

---

## Decision

**UptimeRobot** (SaaS, free tier) for external HTTP endpoint monitoring.

---

## Evaluation of Alternatives

| Option | Hosting | External perspective | Free tier | Operational overhead | Assessment |
|---|---|---|---|---|---|
| **UptimeRobot** | SaaS | ✅ | ✅ | none | ✅ Chosen |
| Uptime Kuma | Self-hosted | only with external VPS | ✅ | requires VPS to operate | ❌ Rejected |
| Grafana Cloud | SaaS | ✅ | ✅ (limited) | some config | viable alternative |
| Healthchecks.io | SaaS | ✅ (cron-style) | ✅ | none | different use case (cron jobs) |

---

## Rationale

1. **External perspective is the requirement.** A self-hosted solution (Uptime Kuma) only provides an external perspective if it runs on a VPS outside the homelab — which introduces a new service to operate, patch, and eventually migrate. This is the same operational overhead that motivated moving from Docker Compose to k3s in the first place.

2. **Alert independence.** UptimeRobot sends alerts via email and can integrate with notification services that are independent of the homelab. If the homelab is down, the alert still arrives.

3. **Zero operational overhead.** No deployment, no updates, no backup needed.

4. **Free tier is sufficient.** The free tier supports enough monitors at 5-minute intervals for a homelab service portfolio.

---

## Consequences

- HTTP endpoint monitors are configured in UptimeRobot for all public-facing services
- Alert notifications go to email (independent of homelab infrastructure)
- UptimeRobot check results are surfaced in Home Assistant via the UptimeRobot integration for dashboard visibility
- No self-hosted monitoring service is added to the k3s cluster for this purpose
