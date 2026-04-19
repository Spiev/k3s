# apps/

Kubernetes manifests for each application service.

Each subdirectory is self-contained and can be deployed independently:

```
kubectl apply -f apps/<service>/
```

## Structure

Every service directory contains a single manifest file with all resources (Namespace, PVC, Deployment, Service). Ingress is in a separate `*-ingress.yaml` excluded from git via `.gitignore` — domains are stored encrypted in SOPS secrets.

Secrets follow the SOPS pattern: `*-secrets.sops.yaml` — encrypted at rest, decrypted by Flux's kustomize-controller at deploy time.

## Services

| Directory | Stack |
|---|---|
| `freshrss/` | FreshRSS, local-path PVC |
| `pihole/` | Pi-hole, LoadBalancer Service |
| `seafile/` | Seafile, MariaDB, Redis |
| `teslamate/` | Teslamate, PostgreSQL, Grafana |
