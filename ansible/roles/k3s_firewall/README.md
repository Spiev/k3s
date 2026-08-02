# role: k3s_firewall

Declarative UFW ruleset for a k3s node, via `community.general.ufw`. Idempotent
and node-agnostic (Server-Node and Agent-Node share it).

## What it does

- Default policies: deny incoming, allow outgoing, **deny routed**.
- Opens node service ports from anywhere: `22` SSH, `6443` API, `8472/udp`
  flannel VXLAN, `10250` kubelet.
- Opens LAN-only ports (`53` DNS, `8080`) from `k3s_firewall_lan_cidrs`.
- **Trusts the CNI bridge** (`cni0`) on input and routed chains — stops UFW from
  dropping/logging intra-cluster pod traffic (IPv6 NDP, ICMPv6 type 135).
- **Allows IGMP + multicast** (`224.0.0.0/4`) — required for mDNS / Google Cast
  discovery (fixes Nest audio dropouts caused by dropped multicast membership).

`80`/`443` are deliberately **not** managed here — see
[`docs/platform/firewall.md`](../../../docs/platform/firewall.md) for the full
rationale, ruleset, and why.

## Key variables

See `defaults/main.yml`. Override real values (`k3s_firewall_lan_cidrs`) in the
gitignored inventory, not here.
