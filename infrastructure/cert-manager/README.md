# cert-manager

Issues + auto-renews Let's Encrypt certs for the public services, replacing the
certbot container on the Docker host (edge flip).

Like `monitoring/`, cert-manager itself is installed **manually via Helm** (not
Flux); only the `ClusterIssuer` is a committed manifest.

## Install

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
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
