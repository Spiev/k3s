# 10 — Volume-Migration: Unverschlüsselt → Verschlüsselt

Dieser Guide beschreibt wie ein laufender Service von einem unverschlüsselten Longhorn-Volume auf ein verschlüsseltes Volume migriert wird, ohne Datenverlust.

**Hintergrund:** Longhorn kann ein unverschlüsseltes Backup nicht direkt als verschlüsseltes Volume restoren (die Rohdaten sind plain ext4, kein LUKS). Der korrekte Weg ist daher: erst unverschlüsselt restoren, dann per Migrations-Pod auf ein neues verschlüsseltes Volume kopieren.

Voraussetzung: [03 — Longhorn](./03-longhorn.md) — verschlüsselte StorageClass (`longhorn-retain-encrypted`) und Crypto Secret eingerichtet.

---

## Übersicht

```
[Alt]  PVC "freshrss-config"       → longhorn-retain (unverschlüsselt)
                ↓ cp -a (Migrations-Pod)
[Neu]  PVC "freshrss-config-enc"   → longhorn-retain-encrypted
                ↓ Deployment umstellen
[Alt]  PVC löschen, Volume aufräumen
```

---

## Schritt 1 — Neues verschlüsseltes PVC anlegen

Das neue PVC bekommt zunächst einen anderen Namen damit das alte noch gebunden bleibt:

```yaml
# /tmp/freshrss-pvc-encrypted.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: freshrss-config-enc
  namespace: freshrss
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-retain-encrypted
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f /tmp/freshrss-pvc-encrypted.yaml
kubectl get pvc -n freshrss
# freshrss-config     Bound   (alt, unverschlüsselt)
# freshrss-config-enc Bound   (neu, verschlüsselt)
```

---

## Schritt 2 — Service stoppen

```bash
kubectl scale deployment freshrss -n freshrss --replicas=0
```

---

## Schritt 3 — Migrations-Pod starten

Der Pod mountet beide PVCs und kopiert die Daten:

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
      command:
        - sh
        - -c
        - |
          echo "Starte Migration..."
          cp -av /source/. /dest/
          echo "Migration abgeschlossen."
          sleep 3600
      volumeMounts:
        - name: source
          mountPath: /source
        - name: dest
          mountPath: /dest
  volumes:
    - name: source
      persistentVolumeClaim:
        claimName: freshrss-config
    - name: dest
      persistentVolumeClaim:
        claimName: freshrss-config-enc
  restartPolicy: Never
```

```bash
kubectl apply -f /tmp/freshrss-migration-pod.yaml

# Fortschritt beobachten
kubectl logs -n freshrss freshrss-migration -f
# "Migration abgeschlossen." abwarten
```

---

## Schritt 4 — Deployment auf neues Volume umstellen

```bash
# Deployment-Manifest anpassen — PVC-Name im Volume referenzieren
# In apps/freshrss/base/deployment.yaml:
#   claimName: freshrss-config  →  claimName: freshrss-config-enc
```

Oder direkt patchen:

```bash
kubectl patch deployment freshrss -n freshrss \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"freshrss-config-enc"}]'

kubectl scale deployment freshrss -n freshrss --replicas=1
kubectl get pods -n freshrss -w
# Warten bis 1/1 Running
```

---

## Schritt 5 — Daten verifizieren

Im Browser prüfen:
- Feeds vorhanden?
- Read-Status korrekt?
- Settings stimmen?

---

## Schritt 6 — Aufräumen

Erst aufräumen wenn Schritt 5 erfolgreich:

```bash
# Migrations-Pod löschen
kubectl delete pod freshrss-migration -n freshrss

# Altes unverschlüsseltes PVC löschen
kubectl delete pvc freshrss-config -n freshrss
# → Volume bleibt wegen Retain in Longhorn erhalten

# Alten PV löschen (falls manuell angelegt)
kubectl delete pv freshrss-config-restored
```

In der **Longhorn UI → Volumes** das alte Volume `freshrss-config-restored` löschen.

---

## Abschluss-Check

```bash
# PVC läuft auf verschlüsselter StorageClass
kubectl get pvc -n freshrss
# NAME                  STORAGECLASS                ...
# freshrss-config-enc   longhorn-retain-encrypted   Bound

# Longhorn UI → Volume → Encrypted: true
# Longhorn UI → Volume → Health: healthy
```

---

## Weiter: [04b — Pi-hole deployen](./04b-pihole.md)
