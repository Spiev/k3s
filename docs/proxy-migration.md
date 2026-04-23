# Proxy Migration: nginx/fail2ban → Traefik/CrowdSec

**Goal:** Traefik on k3s (pi2) becomes the public entry point for all services. nginx and fail2ban on pi1 are decommissioned. Immich and Home Assistant continue to run in Docker on pi1 during the transition — Traefik proxies them via temporary external routes until those services are migrated to k3s.

**Prerequisite:** This migration does NOT require migrating Immich or HA first. They stay on pi1-Docker and are reachable via Traefik proxy until their own k3s migration.

---

## Architecture

### Before (current state)

```
Internet
    │
    ▼ port 80/443
pi1 — nginx (TLS termination, fail2ban, rate limiting)
    │
    ├─ proxy_pass → pi1:2283       Immich (Docker)
    ├─ proxy_pass → pi1:8123       Home Assistant (Docker)
    ├─ proxy_pass → pi2:80         Paperless  ┐
    ├─ proxy_pass → pi2:80         FreshRSS   │ Traefik (HTTP only)
    └─ proxy_pass → pi2:80         Seafile    ┘
```

### After (target state)

```
Internet
    │
    ▼ port 80/443
pi2 — Traefik (TLS termination, CrowdSec, rate limiting, security headers)
    │
    ├─ IngressRoute → freshrss pod           ┐
    ├─ IngressRoute → paperless pod          │ already in k3s
    ├─ IngressRoute → seafile pod            ┘
    ├─ IngressRoute → pi1:2283               Immich (Docker, temp)
    └─ IngressRoute → pi1:8123               Home Assistant (Docker, temp)

pi1 — only Immich + HA Docker containers remain (no nginx, no fail2ban)
```

---

## Domains and services

| Domain | Service | Current backend | After migration |
|---|---|---|---|
| `photos.miesem.de` | Immich | pi1:2283 (Docker) | pi1:2283 (temp external route) |
| `paperless.miesem.de` | Paperless | pi2:80 (k3s) | pi2 (k3s, direct) |
| `rss.miesem.de` | FreshRSS | pi2:80 (k3s) | pi2 (k3s, direct) |
| `ha.miesem.de` | Home Assistant | pi1:8123 (Docker) | pi1:8123 (temp external route) |
| `files.miesem.de` | Seafile | pi2:80 (k3s) | pi2 (k3s, direct) |

Existing cert: SAN cert covering all 5 domains, issued via certbot HTTP-01, valid for ~80 days from migration date.

---

## Certificate strategy

**Key constraint:** cert-manager needs to respond to Let's Encrypt HTTP-01 challenges on port 80. During the transition, nginx on pi1 still owns port 80.

**Approach: nginx relay for ACME challenges**

Before switching the router, nginx proxies `/.well-known/acme-challenge/` for all domains to Traefik on pi2. cert-manager issues fresh certs via Let's Encrypt through this relay. Once all certs are issued and validated, the router is switched.

This gives cert-manager full ownership from day one — no manual cert copying, no risk on next renewal.

```
Let's Encrypt
    │
    │ HTTP-01 challenge: GET /.well-known/acme-challenge/<token>
    ▼
pi1 nginx (still owns port 80)
    │ location /.well-known/acme-challenge/ proxy_pass → pi2:80
    ▼
pi2 Traefik  →  cert-manager ACME solver pod
    │
    │ (returns challenge response)
    ▼
Let's Encrypt validates → issues cert → cert-manager stores in k8s Secret
```

No downtime. No manual cert handling.

---

## Implementation order

```
Phase 1 — cert-manager + TLS
Phase 2 — Traefik hardening (HTTP→HTTPS, security headers, rate limiting, real IP)
Phase 3 — CrowdSec
Phase 4 — Temp external routes (Immich + HA)
Phase 5 — Switchover (router + nginx/fail2ban shutdown)
Phase 6 — Verify
```

---

## Phase 1 — cert-manager + TLS

### 1.1 Install cert-manager

cert-manager is not in Flux yet. Install via Helm (Flux HelmRelease is overkill for a one-time install of a cluster platform component):

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set global.leaderElection.namespace=cert-manager
```

Verify:

```bash
kubectl get pods -n cert-manager
# cert-manager, cert-manager-cainjector, cert-manager-webhook — all Running
```

### 1.2 ClusterIssuer: Let's Encrypt

Create `infrastructure/cert-manager/clusterissuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  labels:
    app: cert-manager
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: claude@spiev.de
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

Also create a staging issuer for testing (avoids rate limits while iterating):

```yaml
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  labels:
    app: cert-manager
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: claude@spiev.de
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

Apply:

```bash
kubectl apply -f infrastructure/cert-manager/clusterissuer.yaml
kubectl get clusterissuer  # both should show READY=True within ~30s
```

### 1.3 Configure nginx to relay ACME challenges

On pi1, add to each server block in the nginx config — or once in the HTTP block if applicable. Since the config uses a template, add this to the HTTP-to-HTTPS redirect server block (port 80):

```nginx
# In the port-80 server block, BEFORE the catch-all redirect:
location /.well-known/acme-challenge/ {
    proxy_pass http://<K3S_IP>/.well-known/acme-challenge/;
    proxy_set_header Host $host;
}
```

`<K3S_IP>` is the MetalLB VIP of the Traefik LoadBalancer service on pi2.

Reload nginx on pi1:

```bash
docker exec proxy-nginx-1 nginx -s reload
```

### 1.4 Issue certificates

Create `infrastructure/cert-manager/certificates.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: miesem-de-tls
  namespace: kube-system        # same namespace as Traefik
  labels:
    app: cert-manager
spec:
  secretName: miesem-de-tls
  issuerRef:
    name: letsencrypt-staging   # switch to letsencrypt-prod after successful test
    kind: ClusterIssuer
  dnsNames:
    - photos.miesem.de
    - paperless.miesem.de
    - rss.miesem.de
    - ha.miesem.de
    - files.miesem.de
```

Apply and watch:

```bash
kubectl apply -f infrastructure/cert-manager/certificates.yaml
kubectl describe certificate miesem-de-tls -n kube-system
kubectl get certificaterequest -n kube-system
# Status should reach: Certificate is up to date and has not expired
```

Once staging cert is issued successfully, switch the issuer to `letsencrypt-prod` and re-apply. Delete the old staging Secret first:

```bash
kubectl delete secret miesem-de-tls -n kube-system
kubectl apply -f infrastructure/cert-manager/certificates.yaml
```

### 1.5 Enable Traefik TLS entrypoint and HTTP→HTTPS redirect

Update `infrastructure/traefik/traefik-config.yaml`:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
  labels:
    app: traefik
    managed-by: flux
spec:
  valuesContent: |-
    # Global HTTP → HTTPS redirect
    ports:
      web:
        redirectTo:
          port: websecure
          priority: 10
      websecure:
        # Traefik is now the outermost layer — no upstream proxy to trust
        forwardedHeaders:
          insecure: false   # do not trust any X-Forwarded-* from outside

    # TLS store: default cert used when no IngressRoute specifies one
    tlsStore:
      default:
        defaultCertificate:
          secretName: miesem-de-tls

    # Enable access log for CrowdSec (Phase 3)
    logs:
      access:
        enabled: true
        filePath: /var/log/traefik/access.log
        format: json

    # Persist access log to host for CrowdSec to read
    deployment:
      additionalVolumes:
        - name: traefik-logs
          hostPath:
            path: /var/log/traefik
            type: DirectoryOrCreate
    additionalVolumeMounts:
      - name: traefik-logs
        mountPath: /var/log/traefik
```

> **Why `insecure: false` instead of `trustedIPs`?**
> Previously Traefik trusted pi1 nginx for `X-Forwarded-For`. Now Traefik is the outermost layer — the FritzBox port forwarding preserves the client's real IP as the TCP source address. Traefik reads the real IP from `$remote_addr` directly. No trusted upstream, no trusted headers needed.

Apply via Flux (push to main) or directly:

```bash
kubectl apply -f infrastructure/traefik/traefik-config.yaml
```

Traefik restarts automatically after HelmChartConfig change.

### 1.6 Update existing IngressRoutes to use TLS

All existing IngressRoutes use `entrypoints: web` (HTTP only). Update each to `websecure` with TLS. The cert is provided via the TLS store default — no per-IngressRoute cert reference needed.

Example — update `apps/freshrss/freshrss-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: freshrss
  namespace: freshrss
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - secretName: miesem-de-tls
  rules:
    - host: rss.miesem.de
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: freshrss
                port:
                  number: 80
```

Apply the same change to `paperless-ingress.yaml`, `seafile-ingress.yaml`, `teslamate-ingress.yaml`, `grafana-ingress.yaml`, `pihole-ingress.yaml`.

---

## Phase 2 — Traefik hardening

### 2.1 Security headers middleware

Create `infrastructure/traefik/middleware-security-headers.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: kube-system
  labels:
    app: traefik
spec:
  headers:
    # HSTS: 1 year, includeSubDomains, preload
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
    forceSTSHeader: true
    # MIME sniffing protection
    contentTypeNosniff: true
    # Clickjacking protection
    customFrameOptionsValue: SAMEORIGIN
    # XSS protection (legacy browsers)
    browserXssFilter: true
    # Referrer policy
    referrerPolicy: strict-origin-when-cross-origin
    # Permissions policy
    permissionsPolicy: "geolocation=(), microphone=(), camera=()"
```

> **HSTS warning:** Once HSTS is active and the browser has cached it, HTTP connections to these domains are refused by the browser for the full `stsSeconds` duration. Only set `stsPreload: true` after the full migration is verified and stable.

### 2.2 Rate limiting middlewares

Create `infrastructure/traefik/middleware-rate-limits.yaml` — mirrors the nginx rate limit zones:

```yaml
# General: 20 req/s, burst 50 — default for most services
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit-general
  namespace: kube-system
  labels:
    app: traefik
spec:
  rateLimit:
    average: 20
    period: 1s
    burst: 50
---
# Login: 5 req/min, burst 10 — auth endpoints
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit-login
  namespace: kube-system
  labels:
    app: traefik
spec:
  rateLimit:
    average: 5
    period: 60s
    burst: 10
---
# API: 100 req/s, burst 50 — general API calls
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit-api
  namespace: kube-system
  labels:
    app: traefik
spec:
  rateLimit:
    average: 100
    period: 1s
    burst: 50
---
# Immich: 100 req/s, burst 200 — gallery thumbnail loading
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit-immich
  namespace: kube-system
  labels:
    app: traefik
spec:
  rateLimit:
    average: 100
    period: 1s
    burst: 200
```

> **Note:** Traefik's `rateLimit` middleware tracks state in memory, per-Traefik-instance. For a single-node cluster this is equivalent to nginx's shared memory zones. When the Agent-Node joins and Traefik potentially runs on multiple nodes, rate limit state is per-node (not shared). This is acceptable for a homelab — revisit when multi-node is active.

### 2.3 Paperless admin/login block

nginx redirects `/admin/login` to `/` to prevent Django's built-in login form from bypassing OIDC. Replicate in Traefik:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: paperless-block-admin-login
  namespace: paperless
  labels:
    app: paperless
spec:
  redirectRegex:
    regex: "^https://paperless\\.miesem\\.de/admin/login.*"
    replacement: "https://paperless.miesem.de/"
    permanent: false
```

Add this middleware to the Paperless IngressRoute.

### 2.4 Connection limiting

nginx uses `limit_conn conn_limit 10/15/20` per service to cap concurrent connections per IP. Traefik's equivalent is `inFlightReq` — it limits concurrent *requests* (not TCP connections, but the effect is the same for HTTP/1.1):

Create `infrastructure/traefik/middleware-conn-limits.yaml`:

```yaml
# Standard: 10 concurrent requests per IP (Paperless, FreshRSS, Seafile)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: conn-limit-standard
  namespace: kube-system
  labels:
    app: traefik
spec:
  inFlightReq:
    amount: 10
    sourceCriterion:
      ipStrategy:
        depth: 1
---
# Medium: 15 concurrent requests per IP (Home Assistant — multiple dashboards/automations)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: conn-limit-medium
  namespace: kube-system
  labels:
    app: traefik
spec:
  inFlightReq:
    amount: 15
    sourceCriterion:
      ipStrategy:
        depth: 1
---
# High: 20 concurrent requests per IP (Immich — parallel thumbnail loading)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: conn-limit-high
  namespace: kube-system
  labels:
    app: traefik
spec:
  inFlightReq:
    amount: 20
    sourceCriterion:
      ipStrategy:
        depth: 1
```

Middleware → service mapping (mirrors nginx `limit_conn` config):

| Service | Middleware | nginx equivalent |
|---|---|---|
| Immich | `conn-limit-high` | `limit_conn conn_limit 20` |
| Home Assistant | `conn-limit-medium` | `limit_conn conn_limit 15` |
| Paperless, FreshRSS, Seafile | `conn-limit-standard` | `limit_conn conn_limit 10` |

### 2.5 Per-service body size limits

nginx enforces `client_max_body_size` per service. In Traefik this is the `buffering` middleware with `maxRequestBodyBytes`:

Create `infrastructure/traefik/middleware-body-limits.yaml`:

```yaml
# 10 MB — FreshRSS (feed imports), Home Assistant (config/snapshots)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: body-limit-10m
  namespace: kube-system
  labels:
    app: traefik
spec:
  buffering:
    maxRequestBodyBytes: 10485760   # 10 * 1024 * 1024
---
# 100 MB — Paperless (large scanned PDFs)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: body-limit-100m
  namespace: kube-system
  labels:
    app: traefik
spec:
  buffering:
    maxRequestBodyBytes: 104857600  # 100 * 1024 * 1024
```

Immich and Seafile have `client_max_body_size 0` in nginx (unlimited). Traefik has no default body size limit — no middleware needed for those two.

Middleware → service mapping:

| Service | Middleware | nginx equivalent |
|---|---|---|
| Immich | none | `client_max_body_size 0` |
| Paperless | `body-limit-100m` | `client_max_body_size 100M` |
| FreshRSS | `body-limit-10m` | `client_max_body_size 10M` |
| Home Assistant | `body-limit-10m` | `client_max_body_size 10M` |
| Seafile | none | `client_max_body_size 0` |

### 2.6 Per-service timeouts for existing k3s services

nginx has per-service `proxy_read_timeout` and `proxy_send_timeout`. For the already-migrated k3s services (Paperless, FreshRSS, Seafile), these need `ServersTransport` resources. The Immich and HA transports are covered in Phase 4.

Create `infrastructure/traefik/servers-transports.yaml`:

```yaml
# Paperless: 2-minute timeout for OCR processing
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: paperless-transport
  namespace: paperless
spec:
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 120s
    idleConnTimeout: 120s
---
# FreshRSS: 1-minute timeout (RSS feeds are fast)
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: freshrss-transport
  namespace: freshrss
spec:
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 60s
    idleConnTimeout: 60s
---
# Seafile: 5-minute timeout for large file transfers
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: seafile-transport
  namespace: seafile
spec:
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 300s
    idleConnTimeout: 300s
```

Reference the transport in the service definition inside each IngressRoute:

```yaml
services:
  - name: paperless-webserver
    port: 8000
    serversTransport: paperless-transport
```

### 2.7 TLS configuration

nginx explicitly enforces `ssl_protocols TLSv1.2 TLSv1.3` and disables session tickets. Traefik's default already matches — but it must be pinned explicitly to prevent a future k3s upgrade from silently enabling TLS 1.0/1.1.

Add to `infrastructure/traefik/traefik-config.yaml` under `valuesContent`:

```yaml
    # TLS options: enforce TLS 1.2+ only, disable session tickets (forward secrecy)
    tlsOptions:
      default:
        minVersion: VersionTLS12
        sniStrict: true
        preferServerCipherSuites: true
        cipherSuites:
          - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
          - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
          - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
          - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
          - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
          - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
```

> Session tickets are disabled by default in Traefik when using cert-manager — no explicit `ssl_session_tickets off` equivalent needed.

---

## Phase 3 — CrowdSec

CrowdSec replaces fail2ban. The architecture: CrowdSec Security Engine (agent + LAPI) runs as a Deployment in k3s. It reads Traefik's access log from the hostPath volume configured in Phase 1. The Traefik Bouncer runs as a plugin inside Traefik and queries CrowdSec's LAPI — banned IPs are rejected at the ingress layer before the request reaches any service.

### fail2ban → CrowdSec scenario mapping

| fail2ban jail | Trigger | CrowdSec equivalent | Gap? |
|---|---|---|---|
| `nginx-4xx` | 3× 401/403/404 in 10 min → 24h ban | `crowdsecurity/http-bf-wordpress_bf_xmlrpc` + `crowdsecurity/traefik` collection | ✅ covered |
| `nginx-malicious-uri` | 3× malicious path in 10 min → 24h ban | `crowdsecurity/base-http-scenarios` (includes path-based scanner detection) | ✅ covered |
| `seafile-auth` | 10× Seafile auth fail in 10 min → 24h ban | `crowdsecurity/http-bf` (generic HTTP brute-force) | ✅ covered, tuning possible |
| `homeassistant-auth` | 3× HA login fail in 10 min → 1h ban | **see note below** | 🔴 gap during transition |
| `recidive` | 3× bans in 24h → 7-day ban | CrowdSec escalation (see below) | ✅ covered differently |

#### Home Assistant auth — critical gap during transition

fail2ban detected HA login failures by reading HA's internal log (`home-assistant.log`), because HA returns **HTTP 200 even for failed logins** — the failure is only visible in the application log, not in the nginx access log.

CrowdSec reads from the Traefik access log and cannot distinguish a successful from a failed HA login at the HTTP layer.

**During the transition (HA still on pi1-Docker):** CrowdSec on pi2 has no access to pi1's HA log. There is no equivalent protection for HA brute-force at the proxy layer.

**Mitigations in place:**
1. HA's built-in brute-force protection: after 5 failed login attempts, HA locks out the user for an increasing duration (built into HA core, independent of the proxy).
2. The `rate-limit-login` Traefik middleware (5 req/min) still throttles the auth endpoint.

**After HA moves to k3s:** CrowdSec can read the HA container log directly via an additional `acquis.yaml` entry pointing to the HA log file. A custom CrowdSec parser for HA's log format exists in the CrowdSec Hub (`crowdsecurity/home-assistant`). Document this in the HA migration guide.

#### Recidive equivalent in CrowdSec

CrowdSec does not have a direct "recidive" jail. Instead, escalation works through:

1. **Decision duration**: CrowdSec scenarios can emit decisions with increasing duration on repeated offenses via the `leakybucket` mechanism.
2. **Blocklist sync**: The CrowdSec community hub shares known-bad IPs across all CrowdSec instances globally — persistent attackers are often already on the community blocklist before a single local alert fires.
3. **Manual escalation**: For persistent offenders, decisions can be added manually with a long duration:
   ```bash
   kubectl exec -n crowdsec deploy/crowdsec -- \
     cscli decisions add --ip 1.2.3.4 --duration 168h --reason recidive
   ```

For a homelab this is acceptable. The community blocklist provides coverage that fail2ban's recidive jail could not.

### 3.1 Create namespace and LAPI secret

```bash
kubectl create namespace crowdsec
```

Generate a bouncer API key — this is the key Traefik uses to authenticate against CrowdSec LAPI:

```bash
# Will be run inside the CrowdSec pod after deployment (see 3.3)
# Placeholder here — key is stored as a SOPS secret
```

Create `apps/crowdsec/crowdsec-secrets.sops.yaml` (encrypt with SOPS after creating):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: crowdsec-secrets
  namespace: crowdsec
stringData:
  BOUNCER_KEY_traefik: "<generate with: openssl rand -hex 32>"
```

Encrypt:

```bash
sops --encrypt --in-place apps/crowdsec/crowdsec-secrets.sops.yaml
```

### 3.2 CrowdSec Deployment

Create `apps/crowdsec/crowdsec.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: crowdsec
  labels:
    type: service
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: crowdsec-config
  namespace: crowdsec
data:
  acquis.yaml: |
    ---
    filenames:
      - /var/log/traefik/access.log
    labels:
      type: traefik
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crowdsec
  namespace: crowdsec
  labels:
    app: crowdsec
spec:
  replicas: 1
  selector:
    matchLabels:
      app: crowdsec
  template:
    metadata:
      labels:
        app: crowdsec
    spec:
      # Pin to Server-Node (pi2) where the Traefik log hostPath lives
      nodeSelector:
        kubernetes.io/hostname: k3s
      containers:
        - name: crowdsec
          image: docker.io/crowdsecurity/crowdsec:latest
          env:
            - name: COLLECTIONS
              # traefik:              Traefik-specific parsers + 4xx/brute-force scenarios
              # base-http-scenarios:  Path-based scanner detection (replaces nginx-malicious-uri)
              # http-cve:             Known CVE exploit patterns
              # http-bf:              Generic HTTP brute-force (replaces seafile-auth, nginx-4xx)
              # home-assistant:       HA-specific parser (active after HA moves to k3s)
              value: "crowdsecurity/traefik crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/http-bf crowdsecurity/home-assistant"
            - name: BOUNCER_KEY_traefik
              valueFrom:
                secretKeyRef:
                  name: crowdsec-secrets
                  key: BOUNCER_KEY_traefik
          volumeMounts:
            - name: traefik-logs
              mountPath: /var/log/traefik
              readOnly: true
            - name: crowdsec-config
              mountPath: /etc/crowdsec/acquis.yaml
              subPath: acquis.yaml
            - name: crowdsec-data
              mountPath: /var/lib/crowdsec/data
          ports:
            - containerPort: 8080   # LAPI
      volumes:
        - name: traefik-logs
          hostPath:
            path: /var/log/traefik
        - name: crowdsec-config
          configMap:
            name: crowdsec-config
        - name: crowdsec-data
          persistentVolumeClaim:
            claimName: crowdsec-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: crowdsec-data
  namespace: crowdsec
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: crowdsec-lapi
  namespace: crowdsec
spec:
  selector:
    app: crowdsec
  ports:
    - port: 8080
      targetPort: 8080
```

### 3.3 Register bouncer key in CrowdSec

After the CrowdSec pod is Running, register the bouncer key (must match the value in the Secret):

```bash
kubectl exec -n crowdsec deploy/crowdsec -- \
  cscli bouncers add traefik-bouncer --key "$(kubectl get secret crowdsec-secrets -n crowdsec -o jsonpath='{.data.BOUNCER_KEY_traefik}' | base64 -d)"
```

### 3.4 Enable Traefik Bouncer plugin

Add the plugin to `infrastructure/traefik/traefik-config.yaml` (in the `valuesContent`):

```yaml
    # CrowdSec Bouncer plugin
    experimental:
      plugins:
        crowdsec-bouncer:
          moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
          version: v1.4.2           # check latest: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/releases
```

Create the bouncer Middleware in `infrastructure/traefik/middleware-crowdsec.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: crowdsec-bouncer
  namespace: kube-system
  labels:
    app: traefik
spec:
  plugin:
    crowdsec-bouncer:
      enabled: true
      logLevel: INFO
      crowdsecLapiKey: "<BOUNCER_KEY_traefik>"   # use SOPS secret or env substitution
      crowdsecLapiHost: crowdsec-lapi.crowdsec.svc.cluster.local:8080
      crowdsecLapiScheme: http
```

> **Secret handling for the plugin Middleware:** Traefik plugin config does not support Kubernetes Secret references directly. Options:
> - Use Flux variable substitution (`${BOUNCER_KEY_traefik}`) from the cluster-vars Secret
> - Or store the key in cluster-vars.sops.yaml and reference via `${VAR}` substitution in the manifest

Add `crowdsec-bouncer` to the middleware chain on all IngressRoutes once CrowdSec is running and verified.

### 3.5 Verify CrowdSec is working

```bash
# Check CrowdSec is reading the Traefik log
kubectl logs -n crowdsec deploy/crowdsec | grep -i "traefik\|acqui"

# Check registered bouncers
kubectl exec -n crowdsec deploy/crowdsec -- cscli bouncers list

# Check active decisions (should be empty initially)
kubectl exec -n crowdsec deploy/crowdsec -- cscli decisions list

# Trigger a test ban (adjust IP)
kubectl exec -n crowdsec deploy/crowdsec -- cscli decisions add --ip 1.2.3.4 --duration 1m --reason test
# Verify Traefik bouncer rejects that IP (curl from that IP or use an ephemeral container)
kubectl exec -n crowdsec deploy/crowdsec -- cscli decisions delete --ip 1.2.3.4
```

---

## Phase 4 — Temp external routes (Immich + HA)

Traefik proxies Immich and HA on pi1 via `Endpoints` + `Service`. When these services are later migrated to k3s, only the IngressRoute target changes — no DNS or cert changes needed.

### 4.1 Immich external route

Create `apps/immich/immich-external.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: immich
  labels:
    type: service
---
# Service without selector — backed by manual Endpoints
apiVersion: v1
kind: Service
metadata:
  name: immich-external
  namespace: immich
spec:
  ports:
    - port: 2283
      targetPort: 2283
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: immich-external
  namespace: immich
subsets:
  - addresses:
      - ip: "${BACKEND_IP}"   # pi1 internal IP, from cluster-vars
    ports:
      - port: 2283
---
# ServersTransport: longer timeouts for ML processing + large uploads
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: immich-transport
  namespace: immich
spec:
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 300s   # ML processing can be slow
    idleConnTimeout: 300s
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: immich
  namespace: immich
spec:
  entryPoints:
    - websecure
  tls:
    secretName: miesem-de-tls
  routes:
    - match: Host(`photos.miesem.de`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: kube-system
        - name: crowdsec-bouncer
          namespace: kube-system
        - name: rate-limit-immich
          namespace: kube-system
      services:
        - name: immich-external
          port: 2283
          serversTransport: immich-transport
    # Strict rate limit for auth endpoints
    - match: Host(`photos.miesem.de`) && PathPrefix(`/api/auth`, `/api/user`)
      kind: Rule
      priority: 10
      middlewares:
        - name: security-headers
          namespace: kube-system
        - name: crowdsec-bouncer
          namespace: kube-system
        - name: rate-limit-login
          namespace: kube-system
        - name: rate-limit-api
          namespace: kube-system
      services:
        - name: immich-external
          port: 2283
          serversTransport: immich-transport
```

> **No body size limit:** Traefik has no default request body size limit (unlike nginx's `client_max_body_size`). Immich video uploads work without additional config.

> **`${BACKEND_IP}`** must be added to `infrastructure/cluster-vars/cluster-vars.sops.yaml` — the internal IP of pi1.

### 4.2 Home Assistant external route

Create `apps/homeassistant/homeassistant-external.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homeassistant
  labels:
    type: service
---
apiVersion: v1
kind: Service
metadata:
  name: ha-external
  namespace: homeassistant
spec:
  ports:
    - port: 8123
      targetPort: 8123
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ha-external
  namespace: homeassistant
subsets:
  - addresses:
      - ip: "${BACKEND_IP}"
    ports:
      - port: 8123
---
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: ha-transport
  namespace: homeassistant
spec:
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 120s
    idleConnTimeout: 300s        # WebSocket connections stay open
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homeassistant
  namespace: homeassistant
spec:
  entryPoints:
    - websecure
  tls:
    secretName: miesem-de-tls
  routes:
    - match: Host(`ha.miesem.de`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: kube-system
        - name: crowdsec-bouncer
          namespace: kube-system
        - name: rate-limit-general
          namespace: kube-system
      services:
        - name: ha-external
          port: 8123
          serversTransport: ha-transport
    # Strict rate limit for auth endpoints
    - match: Host(`ha.miesem.de`) && PathPrefix(`/auth/login`, `/auth/token`)
      kind: Rule
      priority: 10
      middlewares:
        - name: security-headers
          namespace: kube-system
        - name: crowdsec-bouncer
          namespace: kube-system
        - name: rate-limit-login
          namespace: kube-system
      services:
        - name: ha-external
          port: 8123
          serversTransport: ha-transport
```

> **WebSocket:** Traefik supports WebSocket natively (no special config needed). HA's `/api/websocket` works out of the box.

> **Home Assistant `trusted_proxies`:** After the switchover, HA sees Traefik's pod IP as the source (not the client IP). Add Traefik's pod CIDR to `configuration.yaml`:
> ```yaml
> http:
>   use_x_forwarded_for: true
>   trusted_proxies:
>     - 10.42.0.0/16   # k3s pod CIDR
> ```

### 4.3 Add `BACKEND_IP` to cluster-vars

Add to `infrastructure/cluster-vars/cluster-vars.sops.yaml`:

```yaml
stringData:
  BACKEND_IP: "<pi1 internal IP>"   # encrypt with SOPS
```

---

## Phase 5 — Switchover

### 5.1 Pre-switchover checklist

Run these checks while nginx is still the entry point:

```bash
# All certs issued and valid
kubectl get certificate -A
# READY=True for miesem-de-tls

# All pods healthy
kubectl get pods -A | grep -v Running | grep -v Completed

# CrowdSec running and reading logs
kubectl logs -n crowdsec deploy/crowdsec | tail -20

# Traefik serves HTTPS correctly (test via local /etc/hosts override)
echo "<K3S_METALLB_VIP> photos.miesem.de" | sudo tee -a /etc/hosts
curl -v https://photos.miesem.de/api/server/ping
# Remove after test: sudo sed -i '/photos.miesem.de/d' /etc/hosts
```

Test all 5 domains via `/etc/hosts` override before touching the router.

### 5.2 Switch router port forwarding

In the FritzBox: change port forwarding for ports 80 and 443 from pi1's IP to the k3s MetalLB VIP.

This is a single change, takes effect immediately. Rollback: change back within seconds if anything breaks.

### 5.3 Verify from outside

```bash
# From a machine that doesn't use /etc/hosts override (e.g., phone on mobile data)
curl -v https://photos.miesem.de/api/server/ping
curl -v https://ha.miesem.de
curl -v https://rss.miesem.de
curl -v https://paperless.miesem.de
curl -v https://files.miesem.de

# Check cert is from cert-manager (not the old certbot cert)
echo | openssl s_client -connect photos.miesem.de:443 2>/dev/null | openssl x509 -noout -issuer -dates
```

### 5.4 Stop nginx and fail2ban on pi1

Only after external verification passes:

```bash
# On pi1
cd ~/docker/proxy
docker compose down

# Disable fail2ban
sudo systemctl stop fail2ban
sudo systemctl disable fail2ban
```

The ACME relay nginx config is no longer needed — certs renew directly via Traefik from now on.

### 5.5 Remove nginx ACME relay from repo

Remove the `/.well-known/acme-challenge/` proxy pass from the docker-runtime nginx template and commit. This documents that the relay was temporary.

---

## Phase 6 — Verify

### Security headers

```bash
curl -I https://photos.miesem.de | grep -iE "strict-transport|x-content|x-frame|referrer|permissions"
```

Check with [securityheaders.com](https://securityheaders.com) for grade.

### TLS quality

Check with [ssllabs.com](https://www.ssllabs.com/ssltest/) — expect A or A+.

### CrowdSec decisions

```bash
# Simulate a scan (carefully — this hits your own server)
# Better: check CrowdSec hub dashboard or community blocklist sync
kubectl exec -n crowdsec deploy/crowdsec -- cscli decisions list
kubectl exec -n crowdsec deploy/crowdsec -- cscli alerts list
```

### Rate limiting

```bash
# Test login rate limit (5 req/min)
for i in {1..8}; do curl -s -o /dev/null -w "%{http_code}\n" https://photos.miesem.de/api/auth/login; done
# Should see 429 after ~5 requests
```

### Cert auto-renewal

```bash
kubectl get certificate -A
# Check RENEWAL TIME — cert-manager renews at 2/3 of validity period (~30 days before expiry for 90-day certs)
```

---

## Rollback plan

Each phase is independently reversible:

| Phase | Rollback |
|---|---|
| Phase 1 (cert-manager) | Nothing changes externally — nginx still owns port 80/443 |
| Phase 2 (Traefik hardening) | Revert `traefik-config.yaml`, push to main |
| Phase 3 (CrowdSec) | Remove `crowdsec-bouncer` from IngressRoutes; delete CrowdSec Deployment |
| Phase 4 (temp routes) | Delete Immich/HA namespaces — services unreachable until router is switched back |
| **Phase 5 (switchover)** | **FritzBox: switch port 80/443 back to pi1 → nginx takes over again** |

Phase 5 rollback takes seconds. The old nginx config on pi1 is preserved until Immich and HA are migrated to k3s (their own migration step — separate guide).

---

## Middleware stack per service — reference table

Apply these middlewares on each IngressRoute. All middleware names reference `namespace: kube-system` unless noted.

| Service | security-headers | crowdsec-bouncer | rate-limit | conn-limit | body-limit | serversTransport |
|---|---|---|---|---|---|---|
| Immich | ✅ | ✅ | `rate-limit-immich` (general) + `rate-limit-login` (auth) | `conn-limit-high` | none | `immich-transport` |
| Paperless | ✅ | ✅ | `rate-limit-general` + `rate-limit-login` (auth) | `conn-limit-standard` | `body-limit-100m` | `paperless-transport` |
| FreshRSS | ✅ | ✅ | `rate-limit-general` + `rate-limit-login` (greader/login) | `conn-limit-standard` | `body-limit-10m` | `freshrss-transport` |
| Home Assistant | ✅ | ✅ | `rate-limit-general` + `rate-limit-login` (auth) | `conn-limit-medium` | `body-limit-10m` | `ha-transport` |
| Seafile | ✅ | ✅ | `rate-limit-general` | `conn-limit-standard` | none | `seafile-transport` |

---

## Open items / follow-up

- [ ] Traefik Bouncer plugin version: pin to a specific release, add to Renovate tracking
- [ ] CrowdSec community hub enrollment (optional: share threat intelligence)
- [ ] Remove `PROXY_IP` from `cluster-vars.sops.yaml` after switchover (no longer needed)
- [ ] Update existing IngressRoutes (Paperless, FreshRSS, Seafile) to use `IngressRoute` (Traefik CRD) instead of `Ingress` — required to reference `serversTransport` and stack middlewares properly
- [ ] HA migration guide: add CrowdSec `acquis.yaml` entry for HA log + `crowdsecurity/home-assistant` parser (closes the auth-detection gap)
- [ ] Immich and HA migration guides reference this doc's temp routes as the starting state
