# Architecture Decision: k3s as Container Orchestration Platform

**Date:** 2026-03 (project start)
**Status:** Decided

---

## Context

The existing homelab ran all services via Docker Compose on two Raspberry Pi 5 nodes (docker-runtime). As the service portfolio grew, the limitations of Docker Compose became apparent: no built-in ingress, no secret management suitable for a public Git repo, no GitOps workflow, and manual restarts on failure.

The goal was to migrate to a proper orchestration platform that:
- Runs on Raspberry Pi 5 (ARM64)
- Uses Kubernetes — the de facto standard for container orchestration — as the foundation, so that homelab operations reflect production-grade practices and skills remain current
- Builds a small cluster that increases resilience (at minimum for DNS via two Pi-hole instances)
- Supports GitOps (pull-based, declarative)
- Has a viable path from single-node to multi-node

---

## Decision

**k3s** — lightweight Kubernetes by Rancher/SUSE.

---

## Evaluation of Alternatives

| Option | ARM64 | GitOps | Real k8s skills | Complexity | Assessment |
|---|---|---|---|---|---|
| **k3s** | ✅ | ✅ | ✅ | low | ✅ Chosen |
| Docker Compose (status quo) | ✅ | ❌ | ❌ | minimal | No ingress, no GitOps |
| Docker Swarm | ✅ | ❌ | ❌ | low | Maintained, but smaller ecosystem and no GitOps |
| Nomad (HashiCorp) | ✅ | ✅ | ❌ | medium | Good, but smaller ecosystem |
| MicroK8s (Canonical) | ✅ | ✅ | ✅ | medium | Snap-based, heavier than k3s |
| full k8s (kubeadm) | ✅ | ✅ | ✅ | high | Overkill for 2 nodes, high RAM |

---

## Rationale

1. **Designed for ARM64 and edge hardware.** k3s is the reference platform for Raspberry Pi and similar devices — single binary, ~70 MB RAM baseline, no swap required.

2. **Real Kubernetes API.** According to the [CNCF Annual Survey 2024](https://www.cncf.io/reports/cncf-annual-survey-2024/), 80% of organisations run Kubernetes in production — it is the de facto standard for container orchestration. Running it in the homelab ensures that operational experience — manifests, RBAC, ingress, GitOps — is directly transferable to production environments. Nomad is a viable production tool but covers a smaller share of the market; Docker Swarm remains maintained and used in specific niches (simpler setups, operational simplicity), but does not offer the same ecosystem breadth.

3. **Batteries included.** k3s ships with Traefik (ingress), local-path-provisioner (storage), CoreDNS, and metrics-server. No extra installation steps for the core stack.

4. **First-class Flux CD support.** The entire cloud-native GitOps ecosystem (Flux, Helm, cert-manager, SOPS, CrowdSec) works natively against the Kubernetes API — zero friction.

5. **Single-node to multi-node without rearchitecting.** Adding the Agent-Node is a single `k3s agent` join command. Docker Compose has no equivalent migration path.

6. **Immediate resilience gain for DNS.** Pi-hole runs on both nodes behind a MetalLB VIP — DNS stays available even if one node goes down. This was the first concrete availability improvement over the Docker Compose setup, achievable before the full migration is complete.

7. **Active development and large community.** k3s is maintained by SUSE, used in production at scale, and has a large homelab community — documentation, examples, and troubleshooting resources are abundant.

---

## Consequences

- All services are defined as Kubernetes manifests (Deployments, StatefulSets, Services, PVCs)
- Secrets are managed via SOPS + age, committed encrypted to the public repo
- Flux CD handles all deployments — no manual `kubectl apply` in normal operation
- Traefik replaces nginx as the ingress/reverse proxy
- Docker Compose remains in use for services not yet migrated (docker-runtime)
- The Agent-Node joins the cluster once all Docker services are migrated
