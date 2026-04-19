# FreshRSS

Prerequisite: [Install k3s](../platform/k3s-install.md) completed, cluster is running.

FreshRSS is a self-hosted RSS aggregator with a single volume (`/config`) and no external database.

---

## Manifest overview

```
apps/freshrss/
├── freshrss.yaml                  ← Namespace, PVC, Deployment, Service
├── freshrss-ingress.yaml          ← .gitignore (real domain)
├── freshrss-ingress.yaml.example  ← template
└── feeds.opml                     ← feed list export (human-readable backup)
```

---

## Deploy

```bash
# 1. Set your domain
cp apps/freshrss/freshrss-ingress.yaml.example apps/freshrss/freshrss-ingress.yaml
# Edit freshrss-ingress.yaml and enter your real domain

# 2. Apply
kubectl apply -f apps/freshrss/freshrss.yaml
kubectl apply -f apps/freshrss/freshrss-ingress.yaml
```

Monitor status:
```bash
kubectl get all -n freshrss
kubectl get pvc -n freshrss
```

---

## OPML feed backup

`apps/freshrss/feeds.opml` is a committed export of all feed subscriptions. Keep it up to date after significant changes:

```
FreshRSS UI → Settings → Import/Export → Export OPML
```

In an emergency (volume lost): set up FreshRSS fresh and import the OPML — all feeds are back immediately. Read state and cached articles would be gone, feed subscriptions would not.

---

## Troubleshooting

```bash
# Pod not starting?
kubectl describe pod -n freshrss -l app=freshrss
kubectl logs -n freshrss -l app=freshrss

# Ingress not matching?
kubectl describe ingress -n freshrss freshrss

# PVC not bound?
kubectl describe pvc -n freshrss freshrss-config

# FreshRSS shows wrong URLs (http instead of https)?
# The reverse proxy must set X-Forwarded-Proto: https

# nginx resolver.conf Dual-Stack bug:
# The linuxserver.io image generates /config/nginx/resolver.conf on first start.
# In a Dual-Stack cluster this contains IPv6 addresses without brackets — nginx rejects them.
# Fix (run once after first start):
kubectl exec -n freshrss <pod-name> -- sh -c \
  'echo "resolver 10.43.0.10 valid=30s;" > /config/nginx/resolver.conf'
kubectl rollout restart deployment freshrss -n freshrss
# The file is in /config (persistent volume) — fix is permanent.
```
