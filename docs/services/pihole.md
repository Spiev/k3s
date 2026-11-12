# Pi-hole

Prerequisite: [SOPS + age](../platform/sops.md) set up, Dual-Stack cluster running (see [k3s](../platform/k3s.md)).

Pi-hole runs as the DNS resolver for the entire home network via a LoadBalancer service.

> **Network note:** Wi-Fi works for getting started. Ethernet is recommended for permanent production use — it can be switched at any time without redeploying Pi-hole.

---

## Manifest overview

```
apps/pihole/
├── pihole.yaml                  ← Namespace, StatefulSet (2×), PDB, Services, nebula-sync CronJob
├── pihole-secret.sops.yaml      ← SOPS-encrypted admin password
├── pihole-secret.yaml.example   ← template
├── pihole-ingress.yaml          ← .gitignore (admin UI hostname)
└── pihole-ingress.yaml.example  ← template
```

---

## High availability

Two Pi-hole instances run as a StatefulSet, one per node, so DNS stays up while one of them is updated:

```
 LAN client / node ──▶ <server-node-ip>:53 ─┐   ServiceLB (svclb) on every node,
                         <agent-node-ip>:53 ─┤   externalTrafficPolicy: Cluster
                                           ▼
                                   pihole-dns Service ──▶ any Ready pod
                                    ┌──────────────┴──────────────┐
                               pihole-0 (primary)           pihole-1 (replica)
                               config-pihole-0 PVC          config-pihole-1 PVC
                                    │                             ▲
                                    └──── nebula-sync (CronJob) ──┘
                                          Teleporter, every 6 h
```

- **Rolling updates:** `updateStrategy: RollingUpdate` replaces one pod at a time (highest ordinal first) and waits until it is Ready plus `minReadySeconds: 30` before touching the next one. While a pod pulls its new image, the node resolves through svclb and reaches the other pod, so there's no circular DNS dependency.
- **Readiness = DNS answers.** The probe runs `dig @127.0.0.1 pi.hole` (the same check as the image's own `HEALTHCHECK`), not an HTTP check on the web UI.
- **One pod per node:** a required `podAntiAffinity` places the pods on separate nodes, and the `PodDisruptionBudget` (`maxUnavailable: 1`) keeps drains from evicting both. Each `local-path` PVC is pinned to the node where it was first created, so `pihole-0` and `pihole-1` stay on their nodes.
- **Configuration is only edited on `pihole-0`.** The admin UI (`pihole-web` → Ingress) points at `pihole-0` only. `nebula-sync` copies everything from it to `pihole-1` (full Teleporter sync, then a gravity run), overwriting any changes made on the replica. After a change, sync right away instead of waiting for the next run:
  ```bash
  kubectl create job -n pihole --from=cronjob/nebula-sync nebula-sync-manual-$(date +%s)
  kubectl logs -n pihole -l app=nebula-sync --tail=50
  ```
- **Settings in env vars** (`FTLCONF_*`, such as the web port and password) are the same on both pods automatically. Everything else (upstreams, adlists, local DNS records, groups, clients) lives in each pod's PVC and is copied by nebula-sync.
- **Query logs are not synced.** Each instance keeps its own statistics.

Not covered yet: if a whole node goes down, clients that only know that node's IP lose DNS. Fixing that needs a floating IP, which is planned with [MetalLB](../platform/metallb.md). The StatefulSet stays as it is; only the `pihole-dns` Service changes.

---

## Step 1 — Static ULA address on the k3s node

Pi-hole needs a stable IPv6 address to serve DNS reliably. Add a fixed ULA address to the node:

```bash
# Find active connection and interface
nmcli connection show --active

# Add static IPv6 (adjust connection name, e.g. "preconfigured" or "Wired connection 1")
sudo nmcli connection modify "preconfigured" \
  ipv6.addresses "<ULA-PREFIX>::1/64" \
  ipv6.method "auto"

sudo nmcli connection up "preconfigured"

# Verify
ip addr show wlan0   # or eth0
# → <ULA-PREFIX>::1/64 should appear
```

> `ipv6.method auto` keeps SLAAC for global IPv6 reachability and adds the ULA as an additional address.

---

## Step 2 — Create and encrypt the secret

Create and encrypt the secret following the [SOPS workflow](../platform/sops.md) — use `pihole-secret` as the name, `pihole` as the namespace, and `FTLCONF_webserver_api_password` as the key.

---

## Step 3 — Deploy

Order matters: namespace first, then secret, then the rest.

```bash
kubectl create namespace pihole --save-config
kubectl apply -f apps/pihole/pihole-secret.sops.yaml
kubectl apply -f apps/pihole/pihole.yaml
```

> `kubectl apply -f apps/pihole/` would also apply `.example` files — name files explicitly.

Monitor status:
```bash
kubectl get pods -n pihole -w
kubectl get svc -n pihole
# pihole-dns should show EXTERNAL-IP (IPv4 + IPv6)
```

Set up ingress for the admin UI:
```bash
cp apps/pihole/pihole-ingress.yaml.example apps/pihole/pihole-ingress.yaml
# Fill in hostname, then:
kubectl apply -f apps/pihole/pihole-ingress.yaml
```

---

## Step 4 — Test DNS

```bash
dig @<METALLB-IPV4-VIP> google.com
dig @<METALLB-IPV6-VIP> google.com
```

Both queries should return a response.

---

## Step 5 — Update Fritz!Box

Under Home Network → Network → DNS:

- DNS server (IPv4): `<METALLB-IPV4-VIP>`
- DNS server (IPv6): `<METALLB-IPV6-VIP>`

Renew DHCP lease on a client to verify:
```bash
sudo dhclient -r && sudo dhclient
# Or toggle Wi-Fi off/on
```

---

## HA migration (one-time, from the single-replica Deployment)

The Flux `apps` Kustomization has `prune: true`. Removing a resource from `pihole.yaml` deletes it from the cluster, and for a `local-path` PVC that also deletes the data on disk. The migration is therefore split into three commits, and the old PVC is removed last.

### Phase 1: StatefulSet runs alongside the old Deployment

Commit and push `pihole.yaml` with the StatefulSet, headless Service, PDB and CronJob added. The legacy Deployment, its PVC `pihole-config-new` and the `pihole-dns` / `pihole-web` Services stay untouched.

The new pods are labeled `app.kubernetes.io/name: pihole`, not `app: pihole`. The existing Services don't select them, so LAN clients keep using the old pod and nothing changes for them yet.

```bash
flux reconcile kustomization apps --with-source
kubectl get pods -n pihole -o wide -w
# pihole-0 and pihole-1 Running + Ready, on different nodes
```

> Keep phase 1 short. Until phase 2, the old Deployment still uses `Recreate`, so a Renovate image bump during this phase still causes an outage.

**Seed both new instances from the old one.** Run a one-off nebula-sync with the old pod as primary (reached through the `pihole-web` Service, which still points at it) and both new pods as replicas. This Job is not in git, so Flux ignores it:

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: nebula-sync-seed
  namespace: pihole
  labels:
    app: nebula-sync
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: nebula-sync
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
      containers:
        - name: nebula-sync
          image: ghcr.io/lovelaze/nebula-sync:v0.11.3@sha256:59c51378460f6dc8707cc91a16aa62dff5cd5dd8b39353658b45cb00d6bfddd8
          env:
            - name: PIHOLE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pihole-secret
                  key: FTLCONF_webserver_api_password
            - name: PRIMARY
              value: "http://pihole-web.pihole.svc.cluster.local:8080|$(PIHOLE_PASSWORD)"
            - name: REPLICAS
              value: "http://pihole-0.pihole-headless.pihole.svc.cluster.local:8080|$(PIHOLE_PASSWORD),http://pihole-1.pihole-headless.pihole.svc.cluster.local:8080|$(PIHOLE_PASSWORD)"
            - name: FULL_SYNC
              value: "true"
            - name: RUN_GRAVITY
              value: "true"
            - name: CLIENT_TIMEOUT_SECONDS
              value: "120"
EOF
kubectl logs -n pihole job/nebula-sync-seed -f
```

**Verify** that both new pods answer like the old one, including local DNS records. Pod IPs are reachable from the node:

```bash
kubectl get pods -n pihole -o wide          # note the pod IPs
for ip in <old-pod-ip> <pihole-0-ip> <pihole-1-ip>; do
  echo "== $ip"
  dig +short @"$ip" <local-dns-record>   # e.g. a node hostname
  dig +short @"$ip" doubleclick.net         # blocked → 0.0.0.0
  dig +short @"$ip" example.com             # upstream works
done
kubectl exec -n pihole pihole-0 -- pihole-FTL --config dns.upstreams
kubectl exec -n pihole pihole-1 -- pihole-FTL --config dns.upstreams
```

Also test the scheduled sync once: `kubectl create job -n pihole --from=cronjob/nebula-sync nebula-sync-test`.

### Phase 2: switch traffic and remove the Deployment

In `pihole.yaml`:

1. Delete the legacy `Deployment` named `pihole`.
2. Keep the PVC `pihole-config-new` for now and add a comment `# legacy, removed in phase 3`. It's the rollback path.
3. Change the Service selectors:
   ```yaml
   # pihole-dns
   selector:
     app.kubernetes.io/name: pihole                  # both pods
   # pihole-web (admin UI → primary only)
   selector:
     statefulset.kubernetes.io/pod-name: pihole-0
   ```
4. Remove the "Phase 1" comment above the headless Service.

Commit and push. Switching the selector takes effect immediately and the new pods are already Ready, so there's no DNS gap. Verify:

```bash
kubectl get endpointslices -n pihole -l kubernetes.io/service-name=pihole-dns
dig +short @<server-node-ip> <local-dns-record>
dig +short @<agent-node-ip> <local-dns-record>
```

**Node DNS:** give each node both node IPs, the other node first. This isn't strictly needed for pod updates, because either IP reaches any Ready pod through svclb. It only matters when a whole node is down.

```bash
# On each node, find the connection and device first: nmcli -t -f NAME,DEVICE connection show --active

# server node
sudo nmcli connection modify <connection> ipv4.dns "<agent-node-ip> <server-node-ip>"
sudo nmcli device reapply <device>
cat /etc/resolv.conf

# agent node
sudo nmcli connection modify <connection> ipv4.dns "<server-node-ip> <agent-node-ip>"
sudo nmcli device reapply <device>
cat /etc/resolv.conf
```

**Test a rolling update** before the next Renovate PR does it for you. Keep a query loop running in a second terminal while it restarts:

```bash
while true; do dig +short +time=1 +tries=1 @<server-node-ip> example.com >/dev/null || echo "$(date +%T) FAIL"; sleep 0.5; done
kubectl rollout restart statefulset/pihole -n pihole
kubectl rollout status statefulset/pihole -n pihole
```

### Phase 3: remove the old PVC

After a few days without problems, remove `pihole-config-new` from `pihole.yaml`, then commit and push. Flux prunes it, and local-path deletes `/var/lib/rancher/k3s/storage/pvc-<uid>_pihole_pihole-config-new` on the node.

---

## Troubleshooting

```bash
# Pod not starting?
kubectl describe pod -n pihole -l app=pihole
kubectl logs -n pihole -l app=pihole

# DNS service has no External-IP?
kubectl describe svc -n pihole pihole-dns
# → check Events to see if MetalLB assigned an IP from the pool

# Port 53 already in use on the node?
ssh k3s "sudo ss -tulpn | grep :53"
# → systemd-resolved listens on 127.0.0.53, not on the network interface → no conflict

# IPv6 DNS not responding?
ssh k3s "ip addr | grep <ULA-PREFIX>"
# → ULA address <ULA-PREFIX>::1/64 must be present (on wlan0 or eth0)
```
