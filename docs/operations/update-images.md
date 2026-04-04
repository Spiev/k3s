# Image Updates

Anleitung für das manuelle Aktualisieren von Container-Images.

---

## Manuelles Update eines Images

Den neuen Tag im Manifest eintragen und anwenden:

```bash
kubectl apply -f apps/<service>/<service>.yaml
```

Kubernetes erkennt die Änderung und startet einen Rolling Update automatisch.

Fortschritt beobachten:

```bash
kubectl rollout status deployment/<name> -n <namespace>
```

---

## Sonderfall: Services mit RWO-PVC (z.B. Pi-hole)

Services die eine RWO-PVC (ReadWriteOnce) nutzen, verwenden `strategy: Recreate` — der alte Pod wird
zuerst beendet, bevor der neue startet. Beim Image-Pull wird dann DNS (oder ein anderer kritischer
Service) kurzzeitig unterbrochen.

**Lösung: Image vorher manuell pullen** (`crictl` ist bei k3s bereits enthalten):

```bash
sudo crictl pull <image>:<tag>
```

Danach ist das Image lokal gecacht und der Recreate-Downtime reduziert sich auf wenige Sekunden
(kein Pull-Delay mehr).

### Beispiel Pi-hole

```bash
sudo crictl pull pihole/pihole:2026.04.0
kubectl apply -f apps/pihole/pihole.yaml
kubectl rollout status deployment/pihole -n pihole
```

> **Hinweis:** Dieses Problem entfällt sobald Pi-hole als HA-Setup mit zwei Instanzen hinter
> MetalLB betrieben wird (eine Instanz pro Node). Dann sind Rolling Updates ohne Downtime möglich.
