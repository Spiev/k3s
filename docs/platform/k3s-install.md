# Install k3s (Dual-Stack: IPv4 + IPv6)

Prerequisite: [OS Setup](./os-setup.md) completed. Pi is running Raspberry Pi OS Bookworm (64-bit) from NVMe, cgroups active, no swap.

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
  - k3s.fritz.box
cluster-cidr: "10.42.0.0/16,fd42::/56"
service-cidr: "10.43.0.0/16,fd43::/112"
EOF
```

| Parameter | Value | Meaning |
|---|---|---|
| `tls-san` | `k3s.fritz.box` | Hostname in the TLS certificate — enables remote kubectl |
| `cluster-cidr` | `10.42.0.0/16,fd42::/56` | Pod network (IPv4 + IPv6) |
| `service-cidr` | `10.43.0.0/16,fd43::/112` | Service ClusterIPs (IPv4 + IPv6) |

The IPv6 ranges are ULA (Unique Local Addresses, `fd00::/8`) — private, not routed to the internet.

---

## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

The script:
- downloads k3s (single binary, contains everything)
- sets up a systemd service
- starts the cluster using the `config.yaml` from Step 1

Check status:
```bash
sudo systemctl status k3s
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

Copy the kubeconfig from the Pi and update the server address from `127.0.0.1` to the hostname:

```bash
# Run on the laptop:
mkdir -p ~/.kube
scp <user>@k3s.fritz.box:~/.kube/config ~/.kube/config-raspi
sed -i 's/127.0.0.1/k3s.fritz.box/g' ~/.kube/config-raspi
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
sudo journalctl -u k3s -f
```

**Restart:**
```bash
sudo systemctl restart k3s
```

**Uninstall** (deletes everything including etcd):
```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## 9. Updating k3s

k3s is updated by running the install script again — it detects the existing installation and performs an in-place update. The cluster continues running afterwards.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
```

Or pin to a specific version:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.2+k3s1 sh -
```

Check current version:

```bash
k3s --version
```

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
