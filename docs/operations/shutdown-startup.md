# Cluster Shutdown & Startup

Anleitung für sauberes Herunterfahren und Hochfahren des k3s-Clusters.

---

## Shutdown

### 1. Service-Pods herunterskalieren

Alle eigenen Services sauber beenden, damit Longhorn die Volumes vor dem Drain detachen kann:

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

> **`--disable-eviction`** ist nötig, weil Longhornss `instance-manager` ein PodDisruptionBudget hat das den drain sonst dauerhaft blockiert. Beim vollständigen Herunterfahren ist das sicher — es gibt nichts zu schützen.
>
> **`--ignore-daemonsets`** ist nötig, weil Longhorn-Pods als DaemonSet laufen und nicht evicted werden können — das ist normal.

### 4. k3s stoppen und herunterfahren

```bash
sudo systemctl stop k3s && sudo shutdown -h now
```

---

## Startup

### 1. Node hochfahren

k3s startet automatisch via systemd. Nach dem Boot ca. **2–3 Minuten warten** bevor weitergemacht wird.

### 2. Longhorn vollständig abwarten

```bash
# Warten bis alle Longhorn-Pods Running sind
kubectl get pods -n longhorn-system --watch
```

Alle Pods müssen `Running` sein — insbesondere:
- `longhorn-manager`
- `longhorn-admission-webhook`
- `longhorn-csi-plugin`
- `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter`

> **Bekannte Race Condition:** Beim Kaltstart starten alle Longhorn-Pods gleichzeitig. Der `longhorn-manager` wartet max. 2 Minuten auf den `admission-webhook` — klappt das nicht rechtzeitig, crasht er und startet neu (bis zu 8×). Dabei kann der `longhorn-csi-plugin` in einem CrashLoopBackOff hängenbleiben, weil der Manager zwischenzeitlich nicht erreichbar war.
>
> Falls `longhorn-csi-plugin` nach dem Stabilisieren des Managers nicht selbst recovered:
> ```bash
> kubectl delete pod -n longhorn-system -l app=longhorn-csi-plugin
> ```

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

Alle Service-Pods sollten `1/1 Running` erreichen. Longhorn braucht nach dem Volume-Attach noch ~30 Sekunden bis der Pod `Ready` ist.
