# Install k3s (Dual-Stack: IPv4 + IPv6)

Prerequisite: [OS Setup](./os-setup.md) completed. Pi is running Raspberry Pi OS Trixie (64-bit) from NVMe, cgroups active, no swap.

---

## Why Dual-Stack?

Dual-Stack (IPv4 + IPv6 simultaneously) is an **install-time decision** — enabling it afterwards requires a full cluster reinstall. So it is configured from the start.

Dual-Stack is required for:

- **Pi-hole** — must receive IPv6 DNS queries from the LAN; without Dual-Stack a LoadBalancer service gets no IPv6 External-IP
- **Matter Hub** (Home Assistant) — Matter requires IPv6
- **All modern operating systems** — prefer IPv6 when available; DNS queries regularly arrive over IPv6

---

## 1. Create the configuration

Create the k3s configuration before installing — k3s reads it automatically on startup:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
tls-san:
  - <node-hostname>
cluster-cidr: "10.42.0.0/16,fd42::/56"
service-cidr: "10.43.0.0/16,fd43::/112"
flannel-ipv6-masq: true
EOF
```

| Parameter | Value | Meaning |
|---|---|---|
| `tls-san` | `<node-hostname>` | Hostname in the TLS certificate — enables remote kubectl |
| `cluster-cidr` | `10.42.0.0/16,fd42::/56` | Pod network (IPv4 + IPv6) |
| `service-cidr` | `10.43.0.0/16,fd43::/112` | Service ClusterIPs (IPv4 + IPv6) |
| `flannel-ipv6-masq` | `true` | Masquerade (NAT) pod-initiated IPv6 traffic leaving the cluster — see below |

The IPv6 ranges are ULA (Unique Local Addresses, `fd00::/8`) — private, not routed to the internet.

**`flannel-ipv6-masq` is required, not optional, despite not being in k3s's own quick-start examples.** Flannel applies masquerading to pod-egress traffic by default for IPv4 only (`FLANNEL-POSTRTG` chain in `iptables`) — the IPv6 equivalent is opt-in. Without this flag, pods keep their pod-network IPv6 source address (`fd42::/56`) on outbound connections. Since that range isn't routed anywhere outside the cluster, any pod-initiated connection that happens to resolve a dual-stack hostname to its AAAA record hangs until TCP connect times out (~30s) instead of failing fast or falling back to IPv4 — this is what caused the intermittent Seafile/Collabora WOPI open/save errors (`docs/services/seafile.md`). Verify after install:
```bash
sudo ip6tables -t nat -S | grep FLANNEL-POSTRTG   # should list a MASQUERADE rule, not be empty
```
Upstream references: [k3s-io/k3s#4683](https://github.com/k3s-io/k3s/issues/4683), [k3s-io/k3s#5766](https://github.com/k3s-io/k3s/issues/5766).

---

## 2. Install k3s

### Server-Node

```bash
curl -sfL https://get.k3s.io | sh -
```

The script:
- downloads k3s (single binary, contains everything)
- sets up a systemd service (`k3s.service`)
- starts the cluster using the `config.yaml` from Step 1

Check status:
```bash
sudo systemctl status k3s
```

### Agent-Node

The Agent-Node needs only the server address and the join token. Both go into the agent's `/etc/rancher/k3s/config.yaml` — **not** into `K3S_URL`/`K3S_TOKEN` environment variables. The installer rewrites `/etc/systemd/system/k3s-agent.service.env` on every run (including updates) and drops any variables not passed on that run; `config.yaml` is never touched by the installer, so updates cannot lose the join settings.

Read the token on the Server-Node:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

On the Agent-Node (do not paste the token anywhere else — it grants full cluster join rights):
```bash
sudo mkdir -p /etc/rancher/k3s
sudo install -m 600 /dev/null /etc/rancher/k3s/config.yaml
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
server: https://<server-node-ip>:6443
token: <node-token>
EOF

curl -sfL https://get.k3s.io | sh -s - agent
```

The trailing `agent` is essential — without it the script installs a second, independent k3s **server** on this node (see the warning in [§9](#9-updating-k3s)).

Check status (on the Agent-Node, then from the Server-Node):
```bash
sudo systemctl status k3s-agent
kubectl get nodes   # Agent-Node shows up as Ready
```

---

## 3. Set up kubectl

### On the Pi

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

k3s writes the kubeconfig to `/etc/rancher/k3s/k3s.yaml` by default (root-readable only). Set `KUBECONFIG` explicitly — for fish:

```bash
echo 'set -gx KUBECONFIG ~/.kube/config' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

For bash:
```bash
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

`kubectl` now works directly without sudo.

### From the laptop

Install kubectl (Arch Linux):

```bash
sudo pacman -S kubectl
```

**Configure SSH alias** — all commands in this guide use `k3s` as a short alias for the node. Add this once to `~/.ssh/config`:

```
Host k3s
    HostName <node-hostname>   # e.g. 192.168.1.100 or your local DNS name
    User <your-username>
```

Copy the kubeconfig from the Pi and update the server address from `127.0.0.1` to the hostname:

```bash
# Run on the laptop:
mkdir -p ~/.kube
scp k3s:~/.kube/config ~/.kube/config-raspi
sed -i 's/127.0.0.1/<node-hostname>/g' ~/.kube/config-raspi
```

Set `KUBECONFIG` — for fish:
```bash
echo 'set -gx KUBECONFIG ~/.kube/config-raspi' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Test the connection:
```bash
kubectl get nodes
# NAME   STATUS   ROLES           AGE   VERSION
# k3s    Ready    control-plane   ...   v1.x.x+k3s1
```

> **Note:** `~/.kube/config-raspi` contains the client certificate and private key — anyone with this file has full cluster access. Do not commit, do not share.

> **After a cluster reinstall**, k3s generates new TLS certificates. The kubeconfig must be copied from the Pi again (same steps as above).

---

## 4. What k3s ships with

After installation, several system pods are already running:

```bash
kubectl get pods --all-namespaces
```

| Namespace | Pod | Function |
|---|---|---|
| `kube-system` | `traefik-*` | Ingress Controller (HTTP/HTTPS routing) |
| `kube-system` | `coredns-*` | Cluster-internal DNS |
| `kube-system` | `metrics-server-*` | Resource metrics for `kubectl top` |
| `kube-system` | `svclb-traefik-*` | Service LoadBalancer (k3s built-in) |

Flannel (CNI) runs as a kernel module, not as a pod. `local-path-provisioner` is disabled (see configuration above).

---

## 5. Core concepts

The key Kubernetes objects used in this repo: **Pod** (container), **Deployment** (manages pods), **Service** (stable network endpoint), **Namespace** (logical separation), **ConfigMap/Secret** (configuration), **PVC** (storage request), **IngressRoute** (HTTP routing).

→ [Kubernetes Concepts](https://kubernetes.io/docs/concepts/) — particularly Workloads, Services & Networking, Storage

---

## 6. First steps with kubectl

### Basic commands

```bash
# Cluster overview
kubectl get nodes
kubectl get pods --all-namespaces

# Short form: -A instead of --all-namespaces
kubectl get pods -A

# Object details
kubectl describe pod <name> -n <namespace>

# View logs
kubectl logs <pod-name> -n <namespace>
kubectl logs -f <pod-name> -n <namespace>   # live (follow)

# Shell into a running pod
kubectl exec -it <pod-name> -n <namespace> -- sh

# Resource usage
kubectl top nodes
kubectl top pods -A
```

### Deploy something — first experiment

Start an nginx pod without writing YAML:

```bash
# Create namespace
kubectl create namespace test

# Create deployment
kubectl create deployment nginx --image=nginx:alpine -n test

# Wait until the pod is running
kubectl get pods -n test -w   # -w = watch (Ctrl+C to stop)

# Look inside the pod
kubectl exec -it deploy/nginx -n test -- sh
# wget -qO- http://localhost   → prints the nginx start page
exit

# Clean up
kubectl delete namespace test
```

### Understanding YAML — what kubectl actually does

Every `kubectl create` action creates Kubernetes objects. These can also be viewed as YAML:

```bash
kubectl get deployment nginx -n test -o yaml
```

This is the path towards "everything as YAML in the Git repo" — which is what happens later with Flux.

---

## 7. Traefik — the built-in Ingress Controller

Traefik is already running. Check:

```bash
kubectl get svc -n kube-system traefik
# EXTERNAL-IP shows the node IP — with Dual-Stack both (IPv4 + IPv6)
```

Traefik listens on port 80 and 443 of the Raspberry Pi. Everything else is configured via Ingress objects — which comes with the first service (FreshRSS).

**Traefik Dashboard** (local only):
```bash
kubectl port-forward -n kube-system svc/traefik 9000:9000
# Browser: http://localhost:9000/dashboard/
```

---

## 8. k3s-specific details

**Configuration file:** `/etc/rancher/k3s/config.yaml`
```bash
# Changes require:
sudo systemctl restart k3s
```

**Kubeconfig path:** `/etc/rancher/k3s/k3s.yaml`

**Data directory:** `/var/lib/rancher/k3s/`
- `server/db/` — etcd data (cluster state)
- `agent/` — local pod data, images

**Logs:**
```bash
sudo journalctl -u k3s -f         # Server-Node
sudo journalctl -u k3s-agent -f   # Agent-Node
```

**Restart:**
```bash
sudo systemctl restart k3s         # Server-Node
sudo systemctl restart k3s-agent   # Agent-Node
```

**Uninstall** — deletes all of `/var/lib/rancher/k3s/`, **including `storage/` with every local-path PVC** (databases, photos, documents). Only for a deliberate node rebuild with a verified backup:
```bash
/usr/local/bin/k3s-uninstall.sh         # Server-Node
/usr/local/bin/k3s-agent-uninstall.sh   # Agent-Node
```

---

## 9. Updating k3s

> This section is the single source for the k3s update procedure. Other docs and
> `infrastructure/k3s-version.env` link here instead of repeating the commands.

k3s is updated by running the install script again — it detects the existing installation and performs an in-place update. Running containers keep running while the k3s service restarts.

The target version is pinned in `infrastructure/k3s-version.env` (`K3S_VERSION=…`) and tracked by Renovate (→ [Renovate](../operations/renovate.md)): Renovate opens a PR bumping it whenever a new k3s release appears. **Merging that PR changes nothing on the nodes** — the update below has to be run by hand on every node.

> ⚠️ **The install command differs per node role.** The plain server command (`… | sh -`) run on the Agent-Node installs a second, independent k3s *server* there. It generates its own CA, overwrites the agent's certificates under `/var/lib/rancher/k3s/agent/`, and the Agent-Node drops out of the cluster (`x509: certificate signed by unknown authority`, node `NotReady`). This happened once during the v1.37.0 → v1.37.1 update. The command below derives the role from the installed systemd unit, so the same command is correct on both nodes.

**Order:** Server-Node first, then the Agent-Node. Never leave the nodes on different versions longer than necessary.

Run on **each node**, one after the other (no repo checkout needed — the version is read from `main`):

```bash
K3S_VERSION=$(curl -sfL https://raw.githubusercontent.com/Spiev/k3s/main/infrastructure/k3s-version.env \
  | sed -n 's/^K3S_VERSION=//p')
ROLE=$(systemctl cat k3s-agent.service >/dev/null 2>&1 && echo agent || echo server)
echo "Updating $(hostname) as $ROLE to $K3S_VERSION"   # check before continuing

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "$ROLE"
```

- `INSTALL_K3S_VERSION` is what the installer reads; the env file uses the descriptive name `K3S_VERSION`, hence the mapping.
- On the Agent-Node the server address and token come from `/etc/rancher/k3s/config.yaml` ([§2 Agent-Node](#agent-node)) — do **not** pass `K3S_URL`/`K3S_TOKEN` on the command line.
- If the `echo` line prints an empty version or the wrong role, stop and investigate.

Verify (from the Server-Node or laptop):

```bash
kubectl get nodes -o wide   # both Ready, both VERSION = $K3S_VERSION
kubectl get pods -A         # nothing stuck in Pending / ContainerCreating / CrashLoopBackOff
```

If the Agent-Node goes `NotReady` after an update, check `sudo journalctl -u k3s-agent -e` on it and make sure no stray server unit exists there: `systemctl list-unit-files 'k3s*'` must list only `k3s-agent.service`.

> **Traefik version:** Traefik is currently tied to the k3s version — a k3s update automatically brings the associated Traefik version. The long-term solution is to manage Traefik independently of k3s (→ Phase 5, Flux CD).

---

## 10. Final check

```bash
# Node Ready
kubectl get nodes
# STATUS = Ready

# All system pods running
kubectl get pods -A
# All RUNNING or COMPLETED, nothing in CrashLoopBackOff

# Dual-Stack: Traefik has both IPv4 and IPv6 External-IP
kubectl get svc -n kube-system traefik
# EXTERNAL-IP: <IPv4>,<IPv6>

# Resource usage after installation
kubectl top nodes
# k3s uses ~500 MB RAM at idle
```

---

---

## Next: [MetalLB](./metallb.md)
