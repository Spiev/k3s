# Cluster Shutdown & Startup

Guide for gracefully shutting down and starting up the k3s cluster.

---

## Shutdown

### 1. Scale down service pods

```bash
kubectl get ns -l type=service -o name | sed 's|namespace/||' \
  | xargs -I{} kubectl scale deployments --all -n {} --replicas=0
```

> New services are automatically included as long as `type: service` is set on the namespace (convention, see CLAUDE.md).

### 2. Wait for pods to terminate

```bash
kubectl wait --for=delete pod --all --all-namespaces --timeout=120s
```

### 3. Drain node(s)

Order with multiple nodes: Agent-Nodes first, Server-Node last.

```bash
# Agent-Nodes first (once a second node exists)
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o name \
  | xargs kubectl drain --ignore-daemonsets --delete-emptydir-data --disable-eviction

# Server-Node last
kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o name \
  | xargs kubectl drain --ignore-daemonsets --delete-emptydir-data --disable-eviction
```

> **`--disable-eviction`** prevents PodDisruptionBudgets from blocking the drain. Safe during a full shutdown.
>
> **`--ignore-daemonsets`** is required because DaemonSet pods cannot be evicted — this is expected.

### 4. Stop k3s and shut down

```bash
sudo systemctl stop k3s && sudo shutdown -h now
```

---

## Startup

### 1. Boot the node

k3s starts automatically via systemd. Wait **1–2 minutes** after boot before proceeding.

### 2. Check cluster status

```bash
kubectl get pods --all-namespaces
```

### 3. Uncordon nodes

```bash
kubectl get nodes -o name | xargs kubectl uncordon
```

### 4. Scale services back up

```bash
kubectl get ns -l type=service -o name | sed 's|namespace/||' \
  | xargs -I{} kubectl scale deployments --all -n {} --replicas=1
```

### 5. Verify everything is running

```bash
kubectl get pods --all-namespaces
```

All service pods should reach `1/1 Running`.
