# Set up MetalLB

Prerequisite: [Install k3s](./k3s-install.md) completed.

MetalLB is a load balancer for bare-metal Kubernetes. k3s includes a built-in load balancer (Klipper/ServiceLB) that simply binds services to the node IP. MetalLB replaces Klipper and assigns dedicated virtual IPs (VIPs) instead — stable, independent of the node IP, and failover-capable in multi-node setups.

**When is MetalLB needed?**
Whenever a service does not run over HTTP/HTTPS and therefore cannot be routed through Traefik. Pi-hole DNS (port 53) is the first such service.

> [!WARNING]
> **MetalLB only works over Ethernet — not over Wi-Fi.**
>
> MetalLB in Layer-2 mode uses ARP (IPv4) and NDP (IPv6) to announce VIPs on the network. Most Wi-Fi access points and routers do not forward ARP announcements between Wi-Fi clients — the VIP is simply unreachable on the network.
>
> Symptoms: `kubectl get svc` shows an EXTERNAL-IP, but connections to that IP hang (timeout). `curl <VIP>` hangs at "Trying...".
>
> **Klipper/ServiceLB** (the k3s default) binds ports directly on all node interfaces (including Wi-Fi) and is the right choice for Wi-Fi setups. Set up MetalLB only when the node is connected via Ethernet.
>
> More details: [metallb.universe.tf — Layer 2 Limitations](https://metallb.universe.tf/concepts/layer2/#limitations)

---

## Step 1 — Disable k3s ServiceLB

k3s and MetalLB cannot run simultaneously — both would try to serve LoadBalancer services.

On the k3s node:
```bash
sudo vim /etc/rancher/k3s/config.yaml
```

Add the following block (or extend the existing `disable` list):
```yaml
disable:
  - servicelb
```

Restart k3s:
```bash
sudo systemctl restart k3s
```

Verify the Klipper pods are gone:
```bash
kubectl get pods -n kube-system | grep svclb
# → no output
```

---

## Step 2 — Install MetalLB Controller

```bash
# Check current version: https://github.com/metallb/metallb/releases
METALLB_VERSION="v0.14.9"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml
```

Wait until MetalLB is ready:
```bash
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

> **GitOps note:** Loading the manifest directly from the internet is pragmatic for a manual setup. Once Flux CD is configured, the manifest belongs in the repo (`infrastructure/metallb/controller.yaml`).

---

## Step 3 — Configure IP Pool

Before applying, edit `infrastructure/metallb/metallb.yaml` — replace the placeholders with your own values:

| Placeholder | Meaning | Example |
|---|---|---|
| `<METALLB-IPV4-START>` | First free IP outside the DHCP range | first IP after DHCP end |
| `<METALLB-IPV4-END>` | Last IP of the pool | +19 IPs |
| `<ULA-PREFIX>` | ULA prefix of the Fritz!Box (without `::`) | from Fritz!Box network settings |

```bash
kubectl apply -f infrastructure/metallb/metallb.yaml
```

Verify the pool and advertisement were created:
```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

## Step 4 — Verify

Check an existing LoadBalancer service (e.g. Pi-hole):
```bash
kubectl get svc -n pihole pihole-dns
# → EXTERNAL-IP should now show an IP from the configured pool
# → no longer the node IP
```

If the service was already running (with Klipper), it automatically gets a new VIP from the pool after MetalLB is installed.

---

## IP Pool Overview

A table of assigned VIPs helps keep track:

| Service | IPv4 VIP | IPv6 VIP |
|---|---|---|
| Pi-hole DNS | `<first IP from pool>` | `<first IPv6 from pool>` |

> Keep this table up to date manually when new LoadBalancer services are added.

---

## Next: [Deploy Pi-hole](../services/pihole.md)
