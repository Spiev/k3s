# infrastructure/

Platform-level components managed by Flux CD — shared across all services.

Unlike `apps/`, these are not user-facing services but the building blocks everything else depends on.

```
infrastructure/
  cluster-vars/     ← cluster-specific variables (IPs, domains) — SOPS encrypted
  flux/             ← kustomize-controller patch to enable SOPS decryption
  metallb/          ← LoadBalancer IP pool for bare-metal services
  monitoring/       ← kube-prometheus-stack Helm values
  traefik/          ← Traefik ingress controller configuration
  k3s-version.env   ← pinned k3s version, tracked by Renovate for update notifications
```

## Deployment order

Flux deploys `cluster-vars` first (no dependencies), then `infrastructure` (depends on `cluster-vars`). This ensures cluster-specific variables are available as substitution inputs before Traefik config is applied.

See `clusters/raspi/infrastructure.yaml` and `clusters/raspi/cluster-vars.yaml` for the Flux Kustomization definitions.
