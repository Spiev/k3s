# Architecture Decision: Ansible for node/OS configuration (the non-Flux layer)

**Date:** 2026-08-02
**Status:** Decided — first role (`k3s_firewall`) implemented

---

## Context

Flux CD reconciles the cluster's *in-cluster* state (Deployments, Services, Ingress, cert-manager, CrowdSec…) declaratively from this repo. But a k3s node also needs **host-level OS configuration** that has no Kubernetes API representation: the firewall (UFW), sysctl tuning, package/OS setup, and the k3s install itself. Flux cannot manage these — they live on the host, not in the cluster API.

Until now these were applied by hand and captured only as narrative in `docs/platform/` (`os-setup.md`, `k3s-install.md`). The trigger for formalising was the UFW firewall: hand-edited `/etc/ufw/before*.rules` are not reproducible, not reviewable, and drift silently — a problem that worsens once Agent-Node joins and two nodes must stay identical.

**Constraints:**

- Must be reproducible and reviewable, in a **public** repo with **no secrets/IPs leaked**
- Must be idempotent (safe to re-run) and node-agnostic (Server-Node + Agent-Node)
- Should reuse existing tooling/skills where possible
- Runs on Raspberry Pi OS (Debian, ARM64)

---

## Decision

**Ansible** manages the imperative node/OS layer, colocated in this repo under [`ansible/`](../../ansible/). This is explicitly the layer *below* Flux:

| Layer | Scope | Tooling |
|-------|-------|---------|
| Node provisioning (day 0/1) | OS, k3s install, **firewall**, sysctl | **Ansible** (`ansible/`) |
| GitOps reconciliation (day 2) | in-cluster K8s resources | **Flux** (`clusters/`, `apps/`, `infrastructure/`) |

The control node is the workstation (already runs Ansible); managed nodes need only Python + SSH.

---

## Evaluation of Alternatives

| Option | Idempotent | Readable | Existing skill | Multi-node | Assessment |
|---|---|---|---|---|---|
| **Ansible** | ✅ modules | ✅ declarative tasks | ✅ already used | ✅ inventory | ✅ Chosen |
| Custom shell scripts | ⚠️ hand-rolled | ⚠️ bespoke logic | ✅ | ⚠️ manual loops | Workable, but reinvents idempotency |
| cloud-init | ⚠️ first-boot only | ✅ | ❌ | ⚠️ | Provisioning only, not day-2 re-runs |
| Nix / NixOS | ✅ | ✅ | ❌ | ✅ | Powerful, but not RPi OS — full OS rewrite |
| Manual + docs only | ❌ | ✅ | — | ❌ | Not reproducible (the status quo we're leaving) |

---

## Rationale

1. **Clean boundary with Flux.** Flux owns the Kubernetes API; Ansible owns the host OS. Neither reaches into the other's domain, so there is no ambiguity about where a given change belongs.

2. **Idempotent, declarative modules.** `community.general.ufw` expresses the ruleset as named tasks; re-runs converge (`changed=0`) with no bespoke marker/anchor logic a shell script would need.

3. **Already in the toolbox.** Ansible runs on the workstation for other host management — no new technology to learn or maintain.

4. **Scales to multi-node for free.** Agent-Node joins the `k3s` inventory group and gets the identical firewall/host state on the next run — the same driver as the CrowdSec multi-node rationale in [ingress-security.md](ingress-security.md).

5. **Public-repo safe by construction.** Roles are generic (no IPs); real values live only in gitignored `ansible/inventory/hosts.yml`. This matches the repo's existing pattern of `.gitignore`-ing real domains.

---

## Consequences

- `ansible/` holds roles + playbooks; `docs/platform/*` remain the narrative, roles become the executable source of truth.
- Host concerns migrate into roles over time (firewall first; sysctl, os-setup, k3s install are candidates).
- **No auto-reconciliation.** Unlike Flux, Ansible does not continuously enforce state — playbooks are run manually from the workstation (or later via CI/cron). Node config is applied on demand, not drift-corrected automatically. Accepted trade-off for a two-node homelab.
- Secrets are not needed for firewall config; if a future role needs them, use `ansible-vault` or the existing SOPS+age setup rather than plaintext vars.
- First implementation: the `k3s_firewall` role — see [docs/platform/firewall.md](../platform/firewall.md).
