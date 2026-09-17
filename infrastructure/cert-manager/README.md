# cert-manager

Issues + auto-renews Let's Encrypt certs for the public services, replacing the
certbot container on the Docker host (edge flip).

Installed from the **static release manifest** (no Helm — the cluster has no Helm
tooling; plain manifests match the repo style and stay Flux-portable later).
Only the `ClusterIssuer` is a committed manifest here.

## Install

Version is pinned (bump deliberately; mirror the `k3s-version.env` idea).

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=120s
```

## Issuer

`cluster-issuer.yaml` (real file, gitignored — holds the ACME account email) is
derived from `cluster-issuer.yaml.example`. HTTP-01 solver via Traefik.

```bash
cp cluster-issuer.yaml.example cluster-issuer.yaml   # set EMAIL
kubectl apply -f cluster-issuer.yaml
```

> **Timing:** the issuer can be applied anytime, but a `Certificate` only goes
> `Ready` once Traefik holds :80 — i.e. AFTER the Fritzbox forward points at the
> Server-Node (cutover). Until then it stays `pending` (expected). Bridge cert
> serves TLS meanwhile. See the edge-flip plan.
