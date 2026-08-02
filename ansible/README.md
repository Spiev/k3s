# Ansible — node provisioning

Imperative **node/OS layer** for the cluster (see the two-layer split in
[`docs/platform/firewall.md`](../docs/platform/firewall.md)). Flux CD reconciles
*in-cluster* Kubernetes resources; anything on the host OS (firewall, sysctl,
k3s install) lives here instead — Flux never manages host config.

## Layout

| Path | Purpose | Committed? |
|------|---------|-----------|
| `roles/k3s_firewall/` | Generic UFW role — no real IPs, safe in a public repo | ✅ |
| `inventory/hosts.yml.example` | Inventory template with placeholder IPs | ✅ |
| `inventory/hosts.yml` | Real IPs + LAN ranges | ❌ gitignored |
| `playbooks/firewall.yml` | Applies the firewall role to all `k3s` hosts | ✅ |

**All identifying values (host IPs, LAN CIDRs) live only in the gitignored
`inventory/hosts.yml`.** The role itself is generic and public-safe.

## Usage

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml   # once
cp inventory/hosts.yml.example inventory/hosts.yml       # then edit real values

ansible-playbook playbooks/firewall.yml --check --diff   # dry run
ansible-playbook playbooks/firewall.yml                   # apply
```

Idempotent — safe to re-run. When Agent-Node joins, add it under the `k3s` group
in `hosts.yml` and re-run; it gets the identical firewall state.
