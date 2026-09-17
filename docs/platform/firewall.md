# Firewall (UFW)

Host-level firewall for the k3s nodes, managed as code with Ansible.

## Where firewall config belongs: the two-layer model

A k3s + Flux setup has two distinct layers. UFW is in the lower one.

| Layer | Scope | Tooling | In this repo |
|-------|-------|---------|--------------|
| **Node provisioning** (day 0/1) | OS, k3s install, **firewall**, sysctl | imperative — Ansible / docs | [`ansible/`](../../ansible/), `docs/platform/` |
| **GitOps reconciliation** (day 2) | in-cluster K8s resources | declarative — **Flux** | `clusters/`, `apps/`, `infrastructure/` |

Flux reconciles Kubernetes API objects. UFW is a host OS concern with no
Kubernetes resource, so **it is never managed by Flux** — it lives in `ansible/`.

Applying: see [`ansible/README.md`](../../ansible/README.md).

## Ruleset

| Port / rule | Source | Why |
|-------------|--------|-----|
| `22/tcp` | anywhere | SSH |
| `6443/tcp` | anywhere | k3s API server |
| `8472/udp` | anywhere | flannel VXLAN (node-to-node pod net) |
| `10250/tcp` | anywhere | kubelet metrics |
| `53` | LAN | Pi-hole DNS (LoadBalancer) |
| `8080` | LAN | LAN-only app |
| allow in/routed on `cni0` | — | trust the CNI pod bridge |
| IGMP + `224.0.0.0/4` | — | mDNS / Google Cast discovery |

**Not managed by UFW:** `80`/`443`. UFW does not filter the ingress path, so
opening 80/443 in UFW is neither needed nor effective — for both the current and
the target topology:

- **Current state (edge = nginx on `raspberrypi`).** The public entry point is
  nginx in the Docker homelab: it holds the public IP, terminates TLS (certbot →
  Let's Encrypt), runs host-level fail2ban, and reverse-proxies to the
  Server-Node's Traefik over the LAN. Traffic reaching the k3s node arrives from
  nginx and rides the FORWARD + `KUBE-*` / `CNI-HOSTPORT-*` iptables chains into
  `svclb-traefik`, not UFW's INPUT chain.
- **Target state (edge = Traefik, after the edge-flip).** Once cert-manager
  issues certificates in-cluster and the Fritzbox forwards 80/443 straight to the
  Server-Node, internet traffic enters via Fritzbox NAT → k3s ServiceLB hostPort
  (`svclb-traefik`) → Traefik directly. Same iptables path, nginx removed.

Internet-facing security today is nginx + fail2ban (on `raspberrypi`); in the
target state it becomes Traefik middleware (rate-limit/headers, already deployed)
plus **CrowdSec** (decided, not yet deployed) — see
[`docs/decisions/ingress-security.md`](../decisions/ingress-security.md). The
edge-flip (cert-manager → Traefik edge → decommission nginx/fail2ban) is a
distinct, pending migration milestone, not the current state.

## Why the k3s-specific rules exist

- **`cni0` trust.** Pod-to-pod traffic on the flannel bridge (notably IPv6
  Neighbor Discovery, ICMPv6 type 135) hits UFW's forward chain, which has no
  NDP accept, so it is dropped and logged as `[UFW BLOCK] ... IN=cni0 OUT=cni0
  ... TYPE=135` every ~30s. Trusting `cni0` stops it. (Inbound ping was **never**
  blocked — echo-request is accepted by default; type 135 ≠ ping.)
- **IGMP + multicast.** Google Cast / Nest rely on mDNS (`224.0.0.251:5353`) and
  IGMP group membership. UFW drops IGMP (`PROTO=2`) by default, which can break
  multicast discovery and cause audio dropouts. These rules restore it.

## Public-repo hygiene

- The **role** (`ansible/roles/k3s_firewall/`) is generic — no IPs, safe to
  publish.
- Real IPs and LAN CIDRs live **only** in `ansible/inventory/hosts.yml`
  (**gitignored**). Commit `hosts.yml.example` (placeholders) instead.
- No secrets are involved; SOPS is not needed for firewall config.

## History

Rules were first applied by hand to `/etc/ufw/before.rules` and `before6.rules`
(backups: `/etc/ufw/before*.rules.bak-*`) while debugging. After the Ansible role
is applied and verified, revert those manual edits so Ansible is the single
source of truth:

```bash
sudo cp /etc/ufw/before.rules.bak-20260802-104951  /etc/ufw/before.rules
sudo cp /etc/ufw/before6.rules.bak-20260802-104951 /etc/ufw/before6.rules
sudo ufw reload
```
