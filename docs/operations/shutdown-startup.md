# Cluster Shutdown & Startup

Anleitung für sauberes Herunterfahren und Hochfahren des k3s-Clusters.

---

## Shutdown

### 1. Service-Pods herunterskalieren

```bash
kubectl get ns -l type=service -o name | sed 's|namespace/||' \
  | xargs -I{} kubectl scale deployments --all -n {} --replicas=0
```

> Neue Services werden automatisch erfasst, solange `type: service` auf dem Namespace gesetzt ist (Konvention, siehe CLAUDE.md).

### 2. Warten bis Pods beendet sind

```bash
kubectl wait --for=delete pod --all --all-namespaces --timeout=120s
```

### 3. Node(s) drain

Reihenfolge bei mehreren Nodes: Agent-Nodes zuerst, Server-Node zuletzt.

```bash
# Agent-Nodes zuerst (sobald zweiter Node existiert)
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o name \
  | xargs kubectl drain --ignore-daemonsets --delete-emptydir-data --disable-eviction

# Server-Node zuletzt
kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o name \
  | xargs kubectl drain --ignore-daemonsets --delete-emptydir-data --disable-eviction
```

> **`--disable-eviction`** verhindert, dass PodDisruptionBudgets den drain blockieren. Beim vollständigen Herunterfahren ist das sicher.
>
> **`--ignore-daemonsets`** ist nötig, weil DaemonSet-Pods nicht evicted werden können — das ist normal.

### 4. k3s stoppen und herunterfahren

```bash
sudo systemctl stop k3s && sudo shutdown -h now
```

---

## Startup

### 1. Node hochfahren

k3s startet automatisch via systemd. Nach dem Boot ca. **1–2 Minuten warten** bevor weitergemacht wird.

### 2. Cluster-Status prüfen

```bash
kubectl get pods --all-namespaces
```

### 3. Node uncordonen

```bash
kubectl get nodes -o name | xargs kubectl uncordon
```

### 4. Services wieder hochskalieren

```bash
kubectl get ns -l type=service -o name | sed 's|namespace/||' \
  | xargs -I{} kubectl scale deployments --all -n {} --replicas=1
```

### 5. Prüfen ob alles läuft

```bash
kubectl get pods --all-namespaces
```

Alle Service-Pods sollten `1/1 Running` erreichen.
