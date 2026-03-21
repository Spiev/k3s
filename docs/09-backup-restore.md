# 09 — Backup & Restore

Dieser Guide beschreibt die Einrichtung des externen Backup-Speichers, was vor einem Cluster-Rebuild gesichert werden muss, wie Services aus einem Longhorn-Backup wiederhergestellt werden, und welche Secrets außerhalb des Clusters aufbewahrt werden müssen.

---

## Hetzner Object Storage einrichten

Longhorn-Backups auf demselben Node wie die Volumes zu speichern schützt nicht gegen Node-Ausfall oder Disk-Defekt. Ein externer S3-kompatibler Bucket trennt Backup-Storage sauber vom Cluster.

> **Kein offizieller Terraform-Provider:** Hetzner Object Storage wird vom offiziellen `hcloud`-Provider nicht abgedeckt. Buckets werden daher manuell in der Hetzner Console angelegt.

### Schritt 1 — Bucket anlegen

In der [Hetzner Cloud Console](https://console.hetzner.cloud):

1. Projekt öffnen → **Object Storage** → **Bucket erstellen**
2. Location wählen — verfügbar: `fsn1` (Falkenstein) | `nbg1` (Nuremberg) | `hel1` (Helsinki)
3. Name: `bkp-home` (oder eigener Name)
4. Sichtbarkeit: **Private**

### Schritt 2 — Access Key erstellen

1. **Object Storage** → **Access Keys** → **Access Key erstellen**
2. Name: `longhorn-backup`
3. **Access Key ID** und **Secret Key** notieren — der Secret Key wird nur einmalig angezeigt

### Schritt 3 — Longhorn Backup-Target konfigurieren

```bash
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="<hetzner-access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<hetzner-secret-key>" \
  --from-literal=AWS_ENDPOINTS=https://nbg1.your-objectstorage.com
```

In der Longhorn UI unter **Settings → Backup**:
- `Backup Target`: `s3://bkp-home@nbg1/`
- `Backup Target Credential Secret`: `longhorn-backup-secret`

Nach dem Speichern sollte **Backup Target Status: Available** erscheinen.

### Schritt 4 — Backup-Plan einrichten

In der Longhorn UI unter **Recurring Jobs**:

```
Name:       daily-backup
Task:       backup
Cron:       0 2 * * *    (täglich 2:00 Uhr)
Retain:     7            (7 Backups aufbewahren)
```

Diesen Job dann als Default für alle Volumes setzen oder jedem Volume einzeln zuweisen.

---

## Kritische Secrets außerhalb des Clusters

Diese Werte können nicht aus dem Cluster wiederhergestellt werden wenn etcd weg ist. Sie müssen im Passwortmanager liegen — **unabhängig** vom Cluster-Zustand:

| Secret | Exportieren | Aufbewahren |
|---|---|---|
| Longhorn Crypto Key | siehe unten | Passwortmanager |
| Sealed Secrets Key | `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml` | Passwortmanager |
| Hetzner S3 Credentials | Hetzner Console | Passwortmanager |

```bash
# Longhorn Crypto Key exportieren (Klartext-Wert):
kubectl get secret longhorn-crypto-secret -n longhorn-system \
  -o jsonpath='{.data.CRYPTO_KEY_VALUE}' | base64 -d
```

> `sealed-secrets-key.yaml` und den Crypto Key **nie ins Git-Repo committen**.

---

## Vor einem Cluster-Rebuild

### 1. Longhorn-Backup sicherstellen

In der Longhorn UI unter **Backup** prüfen dass ein aktuelles Backup aller Volumes vorhanden ist (State: Completed). Falls nicht, manuell ein Backup triggern bevor der Cluster abgerissen wird.

### 2. Service-Daten per kubectl cp sichern (Fallback)

```bash
# Daten sichern (Pod läuft noch)
kubectl cp freshrss/$(kubectl get pod -n freshrss -o name | head -1 | cut -d/ -f2):/config ./freshrss-config-backup

# Danach skalieren (verhindert Schreibzugriffe während des Backups)
kubectl scale deployment freshrss -n freshrss --replicas=0
```

### 3. Sealed-Secrets-Key exportieren

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.yaml
```

> Im Passwortmanager aufbewahren, nicht ins Repo committen.

---

## Bekannte Limitierungen

### Backups verschlüsselter Volumes sind ebenfalls verschlüsselt

Longhorn sichert die rohen LUKS-Blöcke — nicht die entschlüsselten Daten. Ein Backup eines verschlüsselten Volumes enthält also LUKS-verschlüsselte Blöcke. Das hat zwei Konsequenzen:

- Restore eines verschlüsselten Backups auf ein **unverschlüsseltes** Volume → das Volume enthält LUKS-Blöcke, lässt sich nicht als normales Dateisystem mounten
- Restore eines **unverschlüsselten** Backups auf ein verschlüsseltes Volume → das Volume enthält plain ext4, kein LUKS → Mount schlägt fehl

**Faustregel:** `storageClassName` der Original-PVC (in `apps/<service>/<service>.yaml`) bestimmt den Restore-Pfad. Verschlüsselt → verschlüsselt restoren. Unverschlüsselt → unverschlüsselt restoren.

> **Achtung:** Ohne den Longhorn Crypto Key sind Backups verschlüsselter Volumes **dauerhaft unlesbar**. Der Key muss im Passwortmanager liegen (siehe [Kritische Secrets](#kritische-secrets-außerhalb-des-clusters)).

### `fromBackup`-Annotation funktioniert nicht mit verschlüsselten StorageClasses

Die `longhorn.io/from-backup`-Annotation auf einem PVC funktioniert **nicht** mit verschlüsselten StorageClasses. Das ist ein bekanntes Kubernetes CSI Design-Problem ([Longhorn Issue #9571](https://github.com/longhorn/longhorn/issues/9571)): dynamisch provisionierte PVs erhalten keine `nodeStageSecretRef`/`nodePublishSecretRef` — der Kubelet kann das LUKS-Volume ohne diese Felder nicht entschlüsseln. Longhorn fällt stillschweigend auf ein leeres Volume zurück.

Deshalb müssen PVs bei verschlüsselten Volumes **immer manuell** mit den Secret-Refs angelegt werden (siehe Restore-Prozedur unten).

### Unverschlüsseltes Backup kann nicht direkt als verschlüsseltes Volume restoren

Longhorn kopiert beim Restore die Rohdaten 1:1 zurück. Ein Backup von einem unverschlüsselten Volume enthält plain ext4 — kein LUKS. Wenn beim Restore in der Longhorn UI "Encrypted" angehakt wird, setzt Longhorn zwar das Flag, verschlüsselt die Daten aber nicht. Der anschließende Mount-Versuch schlägt fehl:

```
MountVolume.MountDevice failed: unsupported disk encryption format ext4
```

Der korrekte Weg: erst unverschlüsselt restoren, dann in ein verschlüsseltes Volume migrieren (siehe unten).

---

## Restore nach Cluster-Neuinstall

Reihenfolge: **Longhorn → Backup-Target → Crypto Key → Sealed Secrets → Services**

### 1. Longhorn Backup-Target konfigurieren

Nach dem Neuinstall kennt Longhorn den S3-Bucket nicht mehr:

```bash
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="<hetzner-access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<hetzner-secret-key>" \
  --from-literal=AWS_ENDPOINTS=https://nbg1.your-objectstorage.com
```

In der Longhorn UI unter **Settings → Backup**:
- `Backup Target`: `s3://bkp-home@nbg1/`
  - `bkp-home` = Bucket-Name, `nbg1` = Location
- `Backup Target Credential Secret`: `longhorn-backup-secret`

Nach dem Speichern unter **Backup** prüfen ob die alten Backups erscheinen — Longhorn liest sie automatisch aus dem Bucket.

### 2. Longhorn Crypto Key wiederherstellen

```bash
kubectl create secret generic longhorn-crypto-secret \
  -n longhorn-system \
  --from-literal=CRYPTO_KEY_VALUE="<key-aus-passwortmanager>" \
  --from-literal=CRYPTO_KEY_PROVIDER=secret
```

### 3. Sealed Secrets Controller

```bash
# Aktuelle Version prüfen: https://github.com/bitnami-labs/sealed-secrets/releases
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/<version>/controller.yaml

# Alten Schlüssel einspielen (VOR dem ersten SealedSecret-Deploy!)
kubectl apply -f sealed-secrets-key.yaml

# Controller neu starten damit er den importierten Key lädt
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
```

> Den Key **vor** dem Deployen von SealedSecrets einspielen — sonst generiert der Controller einen neuen Schlüssel und alle bestehenden Sealed Secrets sind nicht mehr entschlüsselbar.

### 4. Services wiederherstellen

Der Restore läuft in zwei Phasen: erst unverschlüsselt restoren und verifizieren, dann in ein verschlüsseltes Volume migrieren.

#### Phase 1 — Unverschlüsselt restoren und verifizieren

**Schritt 1 — Longhorn UI: Backup restoren**

Longhorn UI → **Backup** → Volume auswählen → Backup-Eintrag → **Restore**:
- Volume-Name: `<service>-restored` (z.B. `freshrss-config-restored`)
- **Encrypted: nicht angehakt** (auch wenn das Ziel später verschlüsselt werden soll)
- Data Engine: `v1`
- Access Mode: `ReadWriteOnce`

Warten bis Status `Ready for workload` unter **Volumes**.

> **Single-Node:** Longhorn setzt beim UI-Restore die Default-Replica-Anzahl (3). Da nur ein Node vorhanden ist, wird das Volume `Degraded`. Direkt nach dem Restore die Replica-Anzahl auf 1 setzen:
> ```bash
> kubectl patch volume <volume-name> -n longhorn-system \
>   --type=merge -p '{"spec":{"numberOfReplicas":1}}'
> ```

**Schritt 2 — PV manuell anlegen**

```yaml
# /tmp/<service>-pv-restore.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: freshrss-config-restored
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-retain
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: freshrss-config-restored
```

```bash
kubectl apply -f /tmp/freshrss-pv-restore.yaml
```

**Schritt 3 — PVC anlegen die auf den PV zeigt**

```yaml
# /tmp/<service>-pvc-restore.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-retain
  volumeName: freshrss-config-restored
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f apps/freshrss/base/namespace.yaml
kubectl apply -f /tmp/freshrss-pvc-restore.yaml
kubectl get pvc -n freshrss -w
# STATUS muss Bound sein bevor weitergemacht wird
```

**Schritt 4 — Service deployen und Daten verifizieren**

```bash
kubectl apply -f apps/freshrss/
kubectl get pods -n freshrss -w
# Warten bis 1/1 Running
```

Daten im Browser prüfen — Feeds, Read-Status, Settings müssen vorhanden sein.

#### Alternativ: Restore eines verschlüsselten Volumes (Backup kam von `longhorn-retain-encrypted`)

Wenn das Backup von einem bereits verschlüsselten Volume stammt, kann direkt als verschlüsseltes Volume restoren werden — **kein unverschlüsselter Zwischenschritt nötig**.

**Schritt 1 — Longhorn UI: Backup restoren**

Longhorn UI → **Backup** → Volume auswählen → Backup-Eintrag → **Restore**:
- Volume-Name: `<service>-restored` (z.B. `freshrss-config-restored`)
- **Encrypted: angehakt**
- Secret Namespace: `longhorn-system`
- Secret Name: `longhorn-crypto-secret`
- Data Engine: `v1`
- Access Mode: `ReadWriteOnce`

**Schritt 2 — PV manuell anlegen mit Secret-Refs**

Der PV muss `nodeStageSecretRef` und `nodePublishSecretRef` enthalten — ohne diese Felder kann kubelet das LUKS-Volume nicht entschlüsseln ([Longhorn Issue #9571](https://github.com/longhorn/longhorn/issues/9571)):

```yaml
# /tmp/<service>-pv-restore.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: freshrss-config-restored
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-retain-encrypted
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: freshrss-config-restored
    nodeStageSecretRef:
      name: longhorn-crypto-secret
      namespace: longhorn-system
    nodePublishSecretRef:
      name: longhorn-crypto-secret
      namespace: longhorn-system
```

**Schritt 3 — PVC anlegen und Service deployen**

Analog zur unverschlüsselten Variante, nur mit `storageClassName: longhorn-retain-encrypted`.

---

#### Phase 2 — Migration auf verschlüsseltes Volume

Sobald die Daten verifiziert sind, in ein verschlüsseltes Volume migrieren:

```bash
# 1. Neues leeres verschlüsseltes PVC anlegen
kubectl apply -f apps/freshrss/base/pvc.yaml
# (pvc.yaml verwendet longhorn-retain-encrypted)
# Warten bis das neue PVC einen anderen Namen hat — es ist noch nicht gebunden
```

```bash
# 2. Migrations-Pod starten der beide Volumes mountet
```

```yaml
# /tmp/freshrss-migration-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: freshrss-migration
  namespace: freshrss
spec:
  containers:
    - name: migration
      image: alpine:3.19
      command: ["sh", "-c", "cp -av /source/. /dest/ && echo 'Migration done' && sleep 3600"]
      volumeMounts:
        - name: source
          mountPath: /source
        - name: dest
          mountPath: /dest
  volumes:
    - name: source
      persistentVolumeClaim:
        claimName: freshrss-config          # unverschlüsselt (restored)
    - name: dest
      persistentVolumeClaim:
        claimName: freshrss-config-encrypted  # neu, verschlüsselt
```

```bash
# 3. Migration beobachten
kubectl logs -n freshrss freshrss-migration -f
# "Migration done" abwarten

# 4. Service auf verschlüsseltes Volume umstellen
kubectl scale deployment freshrss -n freshrss --replicas=0
kubectl patch deployment freshrss -n freshrss \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"freshrss-config-encrypted"}]'
kubectl scale deployment freshrss -n freshrss --replicas=1

# 5. Aufräumen
kubectl delete pod freshrss-migration -n freshrss
kubectl delete pvc freshrss-config -n freshrss      # unverschlüsselt
kubectl delete pv freshrss-config-restored
# Longhorn UI: freshrss-config-restored Volume löschen
```

---

## Hinweis: nginx resolver.conf bei Dual-Stack

Das linuxserver.io FreshRSS-Image generiert `/config/nginx/resolver.conf` beim **ersten Start** aus `/etc/resolv.conf`. In einem Dual-Stack-Cluster enthält diese Datei beide Nameserver (IPv4 + IPv6). nginx akzeptiert IPv6-Adressen ohne eckige Klammern nicht:

```
invalid port in resolver "fd43::a"
```

Fix — einmalig nach dem ersten Start ausführen:

```bash
kubectl exec -n freshrss <pod-name> -- sh -c \
  'echo "resolver 10.43.0.10 valid=30s;" > /config/nginx/resolver.conf'
kubectl rollout restart deployment freshrss -n freshrss
```

Da die Datei in `/config` (persistentes Volume) liegt und laut Image-Kommentar nur beim ersten Start generiert wird, ist dieser Fix dauerhaft.

---

## Restore eines einzelnen Services (Cluster läuft)

Falls ein Service ohne Cluster-Neuinstall wiederhergestellt werden muss:

```bash
# 1. Deployment stoppen
kubectl scale deployment <service> -n <namespace> --replicas=0

# 2. PVC löschen (Volume bleibt wegen Retain in Longhorn erhalten)
kubectl delete pvc <pvc-name> -n <namespace>
```

Dann den gleichen Prozess wie oben durchführen (Longhorn UI → PV → PVC → Deployment), danach auf verschlüsseltes Volume migrieren.
