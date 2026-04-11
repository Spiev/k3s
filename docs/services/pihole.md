# Deploy Pi-hole

Prerequisite: [03 — MetalLB](../platform/03-metallb.md) set up, [05 — SOPS + age](../platform/05-sops.md) set up, Dual-Stack cluster running (see [02 — Install k3s](../platform/02-k3s-install.md)).

> [!NOTE]
> MetalLB is **no longer a hard prerequisite** for Pi-hole. Klipper/ServiceLB (the k3s default) binds port 53 directly to the node IP — that is sufficient for DNS. MetalLB only adds value here when the node is connected via Ethernet (stable VIP independent of the node IP). See [03 — MetalLB](../platform/03-metallb.md).

Pi-hole runs as the DNS resolver for the entire home network. Since this is a fresh deployment (no complex data to migrate), the volume is provisioned directly with `local-path`.

> **Network connection note:**
> Pi-hole is DNS for the entire home network. Wi-Fi works for getting started, as long as the connection is stable. Ethernet is recommended for permanent production use — it can be switched at any time without redeploying Pi-hole.

---

## Differences from FreshRSS

| Topic | Detail |
|---|---|
| Port 53 TCP+UDP | No HTTP routing — LoadBalancer directly on port 53 |
| Dual-Stack DNS | Pi-hole must respond on IPv4 + IPv6 |
| Static ULA | Node needs a fixed IPv6 so the DNS IP stays stable |
| `NET_ADMIN` | Capability required for the DNS listener (and optionally DHCP) |
| Admin password | SOPS-encrypted `pihole-secret.sops.yaml` committed to repo |
| Custom DNS | A few hostnames — transferred manually |

---

## Step 1 — Set up a static ULA address on the k3s node

The k3s node gets a fixed IPv6 address from the Fritz!Box ULA prefix (`<ULA-PREFIX>/64`). ULA addresses never change — independent of the ISP prefix. Choose a free address from the ULA range, e.g. `<ULA-PREFIX>::1`.

```bash
# On the k3s node: find active connection and interface
nmcli connection show --active
# → note Name and DEVICE (e.g. "preconfigured" / wlan0, or "Wired connection 1" / eth0)

# Add static IPv6 to the active connection (adjust connection name)
sudo nmcli connection modify "preconfigured" \
  ipv6.addresses "<ULA-PREFIX>::1/64" \
  ipv6.method "auto"        # SLAAC stays active, ULA is added additionally

sudo nmcli connection up "preconfigured"

# Verify (use interface name from nmcli output, e.g. wlan0 or eth0)
ip addr show wlan0
# → <ULA-PREFIX>::1/64 should appear
```

> `ipv6.method auto` keeps SLAAC (for global IPv6 reachability) and adds the ULA as an additional address. Pi-hole responds on both.

---

## Step 2 — Manifest overview

```
apps/pihole/
├── pihole.yaml                  ← in repo (Namespace, PVC, Deployment, Services)
├── pihole-secret.yaml           ← .gitignore (WEBPASSWORD)
├── pihole-secret.yaml.example   ← in repo (template)
├── pihole-ingress.yaml          ← .gitignore (admin UI hostname)
└── pihole-ingress.yaml.example  ← in repo (template)
```

---

## Step 3 — Create secret for admin password

```bash
# Generate plaintext manifest and encrypt with SOPS (replace <your-password>)
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=FTLCONF_webserver_api_password="<your-password>" \
  --dry-run=client -o yaml > apps/pihole/pihole-secret.sops.yaml

SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --encrypt --in-place apps/pihole/pihole-secret.sops.yaml

# Commit to the repo — encrypted values are safe to push publicly
git add apps/pihole/pihole-secret.sops.yaml
git commit -m "feat(pihole): add SOPS-encrypted admin secret"
```

> The secret is deployed in Step 4 — Flux decrypts it in memory and applies it together with all other resources in the same reconciliation pass. No ordering problem.

---

## Step 4 — Deploy manifests

Order matters: namespace first, then secret, then the rest — so the pod starts without an error intermediate state.

```bash
# 1. Create namespace (--save-config prevents a warning on later kubectl apply)
kubectl create namespace pihole --save-config

# 2. Deploy SealedSecret — controller creates the real secret immediately
kubectl apply -f apps/pihole/pihole-secret.sops.yaml

# 3. Deploy PVC, Deployment and Services
kubectl apply -f apps/pihole/pihole.yaml
```

> `kubectl apply -f apps/pihole/` would also apply the `.example` files — so explicitly name the files.

Monitor status:
```bash
kubectl get pods -n pihole -w
# Wait until 1/1 Running

kubectl get svc -n pihole
# pihole-dns should show EXTERNAL-IP (IPv4 + IPv6)
```

Note the External IPs of the `pihole-dns` service — needed in Step 6:
```bash
kubectl get svc -n pihole pihole-dns -o wide
```

---

## Step 5 — Transfer configuration (Teleporter)

Pi-hole has a built-in import/export function that transfers all settings at once: DNS entries, CNAMEs, block lists, whitelists, settings.

**Export on the old Pi-hole:**
Admin UI → **Settings → Teleporter → Backup**

**Import on the new Pi-hole:**
Admin UI → **Settings → Teleporter → Restore** → upload the exported file

---

## Step 6 — Test Pi-hole (before switching)

Test before updating the Fritz!Box:

```bash
dig @<METALLB-IPV4-VIP> google.com
dig @<METALLB-IPV6-VIP> google.com
```

Both queries should return a response. If so: Pi-hole is working correctly.

---

## Step 7 — Update Fritz!Box

In the **Fritz!Box** under Home Network → Network → DNS:

- DNS server (IPv4): `<METALLB-IPV4-VIP>`
- DNS server (IPv6): `<METALLB-IPV6-VIP>`

Then renew the DHCP lease on a client and verify:
```bash
# Linux
sudo dhclient -r && sudo dhclient

# Or simply toggle Wi-Fi off/on
```

---

## Step 8 — Stop the old Pi-hole

Only once DNS is working correctly on all devices:

```bash
# On the old Raspi
cd ~/docker   # or wherever your docker-compose.yml is
docker compose stop pihole
```

Leave the old Pi-hole running (but stopped) for a few days before removing it — as a fallback in case something is wrong.

---

## Troubleshooting

```bash
# Pi-hole pod not starting?
kubectl describe pod -n pihole -l app=pihole
kubectl logs -n pihole -l app=pihole

# DNS service has no External-IP?
kubectl describe svc -n pihole pihole-dns
# → check Events to see if MetalLB assigned an IP from the pool
# → without MetalLB: klipper-lb (k3s built-in ServiceLB) takes over — service binds to node IP

# Port 53 already in use on the node?
ssh stefan@k3s.fritz.box "sudo ss -tulpn | grep :53"
# → systemd-resolved listens on 127.0.0.53, not on the network interface → no conflict

# IPv6 DNS not responding?
ssh stefan@k3s.fritz.box "ip addr | grep <ULA-PREFIX>"
# → ULA address <ULA-PREFIX>::1/64 must be present (on wlan0 or eth0)
```

---

## Next: [Deploy Seafile](./seafile.md)
