# Pi-hole

Prerequisite: [SOPS + age](../platform/sops.md) set up, Dual-Stack cluster running (see [Install k3s](../platform/k3s-install.md)).

Pi-hole runs as the DNS resolver for the entire home network via a LoadBalancer service.

> **Network note:** Wi-Fi works for getting started. Ethernet is recommended for permanent production use — it can be switched at any time without redeploying Pi-hole.

---

## Manifest overview

```
apps/pihole/
├── pihole.yaml                  ← Namespace, PVC, Deployment, Services
├── pihole-secret.sops.yaml      ← SOPS-encrypted admin password
├── pihole-secret.yaml.example   ← template
├── pihole-ingress.yaml          ← .gitignore (admin UI hostname)
└── pihole-ingress.yaml.example  ← template
```

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
