# Architecture Decision: Deep Cluster Monitoring (kube-prometheus-stack)

**Date:** 2026-11-10
**Status:** Decided — implementation starting

---

## Context

Today's monitoring has two layers:

1. **Home Assistant / MQTT** (`scripts/k3s-monitor.sh`) — pushes coarse node metrics
   (CPU/RAM/disk/temperature/fan/undervoltage) and coarse cluster signals (node
   ready, unhealthy pod count, unbound PVC count, Flux sync status) into HA every
   5 minutes. HA is the dashboard and the alerting channel (automations).
2. **UptimeRobot** (SaaS, external) — checks public endpoint reachability from
   outside the homelab. See [Decision: Uptime Monitoring](uptime-monitoring.md).

Both answer "is something broadly wrong" but neither answers "**which** workload
is causing it" or "**how did this develop over time**":

- No per-pod / per-namespace resource data — only a whole-node snapshot plus a
  binary unhealthy-pod count.
- No historical resolution beyond what happens to be retained in HA's recorder
  (not designed for this purpose — confirmed empirically: a direct history-API
  query returned only partial, inconsistent day-sized windows instead of a
  continuous series).
- No visibility into PVC fill trends per volume, request/error rates, or
  resource saturation building up before it becomes an outage.
- No resource `limits` exist on any Deployment cluster-wide today — meaning
  there is also nothing to compare current usage against (is this normal or
  already a leak?).

**Hardware constraint that shapes every decision below:** 2× Raspberry Pi 5,
8 GB RAM each. The Agent-Node already carries the full application workload
(Immich, Seafile, Paperless, Home Assistant, Mosquitto, Teslamate, …) — there is
no free headroom to simply drop a new stack on it without thought. The
Server-Node runs only the control plane and Traefik, with more headroom since
the NVMe swap (see [Architecture Overview](../architecture.md)).

**Assumption carried through this decision:** the user wants a widely-used,
*standard* Kubernetes solution for bottleneck detection (not a bespoke
extension of the existing HA script), while keeping the HA/MQTT layer and
UptimeRobot exactly as they are today — this ADR only adds a layer, it does
not replace either.

---

## Decision

Add **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager +
node-exporter + kube-state-metrics, the de-facto standard Kubernetes metrics
stack) as a dedicated deep-metrics layer, v1 scoped to dashboards only (no
alerting yet, no app-specific exporters yet — see sub-decisions 4 and 7).
Values live at `infrastructure/monitoring/kube-prometheus-stack.yaml`
(Namespace + HelmRepository + HelmRelease), documented in
[Monitoring](../operations/monitoring.md).

**Rollout mechanism (superseding the original "manual Helm" plan):** Flux's
Helm-controller — already part of the `flux bootstrap` install
(`clusters/raspi/flux-system/gotk-components.yaml`), running but previously
unused (no `HelmRepository`/`HelmRelease` existed yet) — reconciles the
stack as a `HelmRelease`. No new Flux component is added; see sub-decision 5.

Out of the box, and **without touching any existing app manifest**,
node-exporter + kube-state-metrics give per-pod/per-namespace CPU, RAM, PVC
fill level and restart-count history — directly closing the gap above.

### Sub-decisions (so this is reviewable later)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Placement:** pin the stack to the Server-Node via `nodeSelector`/affinity (same pattern already used for Traefik). | Server-Node has headroom (control plane + Traefik only); Agent-Node is already fully loaded with application workloads. |
| 2 | **Resource limits:** set explicit `requests`/`limits` on Prometheus, Grafana and Alertmanager containers from day one; total stack budget capped at **~1.75 GB RAM** (Grafana raised from an initial 300 Mi to 500 Mi after an observed OOM-kill once all 28 default dashboards + the Traefik dashboard were loaded — see Consequences). | The cluster-wide absence of resource limits is a known gap; adding another unbounded, potentially RAM-hungry stack on 8 GB hardware without limits would repeat the same mistake at a larger scale. The budget is a deliberately-set ceiling, revised once against real usage rather than left to chart defaults. |
| 3 | **Exposure:** a real (gitignored) Ingress, LAN-only via the existing `lan-only` Traefik middleware pattern (already used for Pi-hole-web, Teslamate-Grafana) — not exposed to the internet. | It is a diagnostic tool for the operator only; no reason to add public attack surface for it. |
| 4 | **Alerting (v1 scope):** none. Alertmanager ships with the chart but no custom rules/receivers are configured yet — v1 is dashboards-only. | Keeps the first rollout small and verifiable; alert rules + a notification channel (and the eventual split against HA/MQTT's existing automations) are deferred to a follow-up once real dashboard data exists to base thresholds on. |
| 5 | **Deployment mechanism:** manage the stack as a `HelmRelease`, reconciled by Flux's existing Helm-controller (already running, previously unused — see above) like everything else under `infrastructure/`/`apps/`. | Supersedes the originally-considered "manual helm install" (matching cert-manager/MetalLB) — corrected once it turned out Flux already had a working Helm-controller. Brings drift detection and automatic apply for *all* future Helm charts, not just this one. **Consequence:** Renovate can potentially track the chart version going forward (to be confirmed once configured); no plaintext `helm install` command or flag history anywhere. |
| 6 | **Storage sizing:** 30-day retention, 10 Gi Prometheus / 2 Gi Grafana / 1 Gi Alertmanager on `local-path` (in `kube-prometheus-stack.yaml`). | Starting point only — **flagged as open**: Server-Node disk usage has been observed trending upward (roughly 44% → 71% over the last two months); these sizes should be re-checked once the stack is live and real usage is measured, rather than treated as final. |
| 7 | **Scrape scope (v1):** the stack's built-in standard targets (node-exporter, kube-state-metrics → Node/Pod/PVC metrics) **plus Traefik** (its built-in Prometheus metrics, enabled via `infrastructure/traefik/traefik-config.yaml`). Still no other app-specific exporters (Postgres, …) yet. | Originally scoped to standard-only; Traefik was pulled into v1 on request since it's the single internet-facing component and its own chart already ships a Prometheus endpoint + optional ServiceMonitor — zero extra moving parts to wire up (just two `enabled: true` flags plus one Prometheus-side discovery flag). Other app exporters stay deferred — those need actual exporter sidecars, not just a flag flip. |
| 8 | **Secrets:** Grafana admin credentials via a SOPS-encrypted Secret (`*.sops.yaml`), like every other service in this repo — not passed via `--set` on the CLI. | Keeps the public-repo convention consistent; no credential ever appears in a shell history or an uncommitted flag. |
| 9 | **Backup:** Prometheus/Grafana/Alertmanager data is explicitly **excluded** from the Restic backup routine. | The data is fully reproducible by re-running the `HelmRelease` against the versioned `values.yaml` — not worth the backup/restore overhead for disposable metrics history. Revisit only if hand-built Grafana dashboards are added later (those would be version-controlled as code instead, not backed up as PVC data). |

---

## Evaluation of Alternatives

| Option | Gives per-pod/historical data? | Footprint on 8 GB Pi | Operational overhead | Assessment |
|---|---|---|---|---|
| **kube-prometheus-stack** | ✅ out of the box | Medium (mitigated by limits + Server-Node placement) | One-time Helm install + periodic manual upgrade | ✅ Chosen |
| Keep status quo (HA/MQTT + UptimeRobot only) | ❌ node-level only, no history | None (already running) | None | ❌ Rejected — doesn't close the stated gap |
| Extend the MQTT script with `kubectl top pods` sampling | Partial (snapshot only, no real time-series storage) | Minimal | Low, but reinvents what Prometheus already solves | ❌ Rejected — not a "standard solution", and still no proper history |
| VictoriaMetrics + a slim Grafana (lighter-weight alternative to the full stack) | ✅ | Lower than kube-prometheus-stack | Non-standard chart/CRD set, more manual wiring | Viable alternative, not chosen — user explicitly asked for *the* standard k8s solution, and `values.yaml` for kube-prometheus-stack was already prepared |

---

## Rationale

1. **Closes the actual gap named by the user** — pod/namespace-level resource
   usage and bottleneck detection, which neither HA/MQTT nor UptimeRobot can
   provide by design.
2. **Zero changes required to existing application manifests** — node-exporter
   and kube-state-metrics scrape everything automatically.
3. **It is the industry-standard choice**, which was an explicit requirement
   ("Standard Lösung für k8s Umgebungen") — not a bespoke homelab script.
4. **The hardware constraint is addressed by placement + limits, not by
   avoiding the stack** — Raspberry Pi RAM pressure is real but manageable with
   the sub-decisions above, rather than a reason to settle for a lesser tool.

---

## Consequences

- HA/MQTT (`scripts/k3s-monitor.sh`) and UptimeRobot are unchanged and continue
  to be the primary dashboards for coarse node/cluster/Flux health and external
  reachability.
- Flux's existing Helm-controller (previously unused) now reconciles a real
  `HelmRelease` — no new Flux component needed, see sub-decision 5.
- A new `monitoring` namespace and `HelmRelease` exist cluster-wide, reconciled
  by Flux — see sub-decision 5.
- Grafana is reachable only from the LAN via a gitignored Ingress + the
  `lan-only` middleware; no new public attack surface is added.
- Resource `limits` exist for the monitoring stack's own pods from the first
  install, capped at ~1.75 GB RAM total (Grafana raised post-launch after an
  OOM-kill — see sub-decision 2) — a model other Deployments cluster-wide
  still lack (tracked separately, see the security hardening notes).
- No alerting in v1 — Alertmanager ships but is unconfigured; a follow-up
  decision is needed once dashboard data exists to base thresholds on.
- Storage sizing for Prometheus/Grafana/Alertmanager is a starting point and
  explicitly flagged for review once real usage data exists (sub-decision 6).
- Prometheus/Grafana/Alertmanager data is excluded from Restic backups —
  reproducible via Flux re-reconcile against `values.yaml`, not treated as
  durable data.
- No credentials, dashboards with real data, or real IPs/domains from this
  rollout are committed to this public repo — the Grafana admin credential is
  a SOPS-encrypted Secret, and only the generic `values.yaml` + this ADR are
  plaintext in Git.
