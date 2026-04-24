# Architecture Decision: UptimeRobot for External Uptime Monitoring

**Date:** 2026-04-24
**Status:** Decided — implementation pending

---

## Context

### Two monitoring layers

Monitoring is split into two independent layers with different failure modes:

**Layer 1 — Internal cluster health (Home Assistant/MQTT)**

`scripts/k3s-monitor.sh` runs on the k3s node, collects metrics, and pushes them via MQTT Discovery to Home Assistant. Covers:

- Node metrics: CPU, RAM, disk, temperatures, fan, undervoltage
- Cluster state: Node Ready, unhealthy pods, unbound PVCs
- Flux CD: sync status, Git revision vs. applied revision

HA automations alert on: node not ready, unhealthy pods, undervoltage, high temperatures, Flux out of sync. → [Monitoring operations guide](../operations/monitoring.md)

**Layer 2 — External reachability (this decision)**

The internal stack has a fundamental blind spot: if the cluster itself is down, or if Traefik or network routing fails, the internal monitor goes down with it. A second, independent layer is required to answer "can a user on the internet actually reach this service right now?"

**Constraints:**

- Must run outside the k3s cluster — otherwise defeats the purpose
- Must not require self-hosted infrastructure (no additional VPS to operate and maintain)
- Notifications must arrive independently of the monitored infrastructure — if the cluster is down, Home Assistant is likely also unreachable, making HA-based alerting circular and useless for this use case
- Free tier must be sufficient for the number of services

---

## Decision

**UptimeRobot** (free tier, SaaS) for external HTTP/HTTPS reachability checks.

---

## Evaluation of Alternatives

| Option | Hosting | IaC | Free tier | HA integration | Assessment |
|---|---|---|---|---|---|
| **UptimeRobot** | SaaS | ❌ | ✅ 50 monitors, 5 min | ✅ Telegram + Email | ✅ Chosen |
| Uptime Kuma | Self-hosted | manual | ✅ | ✅ | Adds a service to operate and migrate |
| healthchecks.io | SaaS | ❌ | heartbeats only¹ | ✅ | Already used for backup heartbeats — different use case |
| Grafana Cloud | SaaS | ✅ | limited | via Alertmanager | Overkill, heavy stack |
| GitHub Actions cron | SaaS | ✅ | ✅ | via webhook | Brittle, no status page, not purpose-built |

¹ healthchecks.io HTTP checks are a paid feature; the free tier covers cron/heartbeat monitoring only — which is already used for backup jobs.

---

## Rationale

**Why UptimeRobot over Uptime Kuma:**

Uptime Kuma is the obvious self-hosted choice, but it requires an external host (a VPS or similar) to be meaningful. That introduces a new service to operate, patch, and eventually migrate — the same operational overhead that motivated moving from Docker Compose to k3s in the first place. For a homelab with no public status-page requirement, SaaS is the pragmatic choice.

**Why not extend healthchecks.io:**

healthchecks.io HTTP checks require a paid plan. The free tier covers only cron/heartbeat monitoring, which is already used for backup jobs. Keeping the two concerns separate (backup heartbeats vs. service reachability) also avoids coupling.

**Why UptimeRobot specifically:**

50 monitors at 5-minute intervals is more than sufficient. Native Telegram and email integration covers the notification requirement without any webhook infrastructure on the cluster side.

---

## Monitored endpoints

| Service | Endpoint | Check |
|---|---|---|
| Immich | `https://photos.<your-domain>/api/server/ping` | HTTP 200, body contains `pong` — functional check, app must be running |
| Paperless | `https://paperless.<your-domain>` | HTTP 200/302 |
| FreshRSS | `https://rss.<your-domain>` | HTTP 200/302 |
| Home Assistant | `https://ha.<your-domain>` | HTTP 200/302 |
| Seafile | `https://files.<your-domain>` | HTTP 200/302 |

Immich provides the strongest functional check: `/api/server/ping` is unauthenticated and responds only when the application layer is healthy — not just when Traefik is up.

Grafana (Teslamate) is intentionally excluded — it is not publicly reachable.

---

## Notification strategy

**Primary: Telegram** — push notification to phone, immediate, fully independent of the cluster. UptimeRobot has native Telegram integration (no bot setup required on the cluster side).

**Secondary: Email** — silent fallback, independent of all infrastructure. Catches cases where Telegram itself is unavailable.

Home Assistant is intentionally *not* used as a notification channel for UptimeRobot alerts. HA runs inside the cluster — if the cluster or Traefik is the cause of the outage, HA is likely unreachable too, making it a circular dependency. HA remains the right place for *internal* cluster alerts (pod crashes, Flux errors, node health) where the cluster itself is still running.

---

## Consequences

- UptimeRobot account required (free tier sufficient)
- Telegram bot token required — created once via @BotFather, stored in Vaultwarden
- Monitors are configured manually in the UptimeRobot UI — no IaC
- When new public services are added, a monitor must be added manually in UptimeRobot
- The two monitoring layers remain independent by design: UptimeRobot detects external reachability failures; Home Assistant/MQTT detects internal cluster failures
