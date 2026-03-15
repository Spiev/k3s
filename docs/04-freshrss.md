# 04 — FreshRSS deployen & migrieren

Voraussetzung: [03 — Longhorn](./03-longhorn.md) abgeschlossen.

FreshRSS ist der erste Service der von Docker auf k3s migriert wird. Er hat ein einziges Volume (`/config`) und keine externe Datenbank — ideal zum Einstieg.

---

## Übersicht der Manifeste

```
apps/freshrss/
├── base/                              ← ins Repo (keine sensiblen Infos)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── pvc.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml                   ← Platzhalter-Domain
└── overlays/
    └── raspi/
        ├── kustomization.yaml         ← ins Repo
        ├── ingress-patch.yaml         ← .gitignore (echte Domain)
        └── ingress-patch.yaml.example ← ins Repo (Template)
```

Die echte Domain steht ausschließlich in `ingress-patch.yaml`, die per `.gitignore` nicht ins Repo kommt.

---

## 1. Domain eintragen

```bash
cd apps/freshrss/overlays/raspi
cp ingress-patch.yaml.example ingress-patch.yaml
# ingress-patch.yaml editieren und echte Domain eintragen
```

---

## 2. Manifeste anwenden

Mit Kustomize (in `kubectl` eingebaut):

```bash
kubectl apply -k apps/freshrss/overlays/raspi/
```

Status beobachten:
```bash
kubectl get all -n freshrss
# Pod sollte nach ~30 Sekunden Running und Ready 1/1 sein

kubectl get pvc -n freshrss
# STATUS = Bound → Longhorn hat das Volume bereitgestellt

kubectl get ingress -n freshrss
# Zeigt die konfigurierte Domain und die Node-IP
```

---

## 3. Kurzer Funktionstest (vor der Migration)

Bevor die Daten migriert werden, prüfen ob FreshRSS überhaupt startet:

```bash
# Port-Forward direkt auf den Pod
kubectl port-forward -n freshrss deploy/freshrss 8080:80
```

Browser: `http://localhost:8080` → FreshRSS-Einrichtungsseite sollte erscheinen.

Wenn das funktioniert: Port-Forward beenden (`Ctrl+C`), weiter zur Datenmigration.

---

## 4. Vorbereitung: OPML-Export

Bevor die Migration startet, Feed-Liste als OPML exportieren und ins Repo committen. Das ist die Absicherung für den Fall dass beim Datentransfer etwas schiefläuft — die Feed-Abonnements sind damit unabhängig von der Datenbank gesichert.

In der FreshRSS-UI auf dem alten Raspi:
```
Einstellungen → Importieren/Exportieren → OPML exportieren
```

Die heruntergeladene Datei ins Repo legen:
```bash
cp ~/Downloads/freshrss-export.opml apps/freshrss/feeds.opml
git add apps/freshrss/feeds.opml
git commit -m "chore(freshrss): add opml feed export pre-migration"
```

Die OPML-Datei nach jeder größeren Änderung an den Abonnements aktuell halten — sie dient langfristig als lesbares Backup der Feed-Liste, unabhängig vom Longhorn-Volume.

**Im Notfall** (Volume verloren, Neustart von Null): FreshRSS neu aufsetzen, OPML importieren → alle Feeds sind sofort wieder da. Gelesener Status und gecachte Artikel wären weg, die Feeds selbst nicht.

---

## 6. Datenmigration

### Strategie

```
Docker FreshRSS stoppen
  → config-Verzeichnis auf den neuen Raspi kopieren
    → in das Longhorn-PVC einspielen
      → nginx auf neuen Raspi umleiten
        → Docker-Container entfernen
```

Docker und k3s laufen auf verschiedenen Rechnern — der Datentransfer geht über SSH.

### Schritt 1 — Docker FreshRSS stoppen

Auf dem alten Raspi:
```bash
cd ~/docker/freshrss    # oder wo auch immer dein docker-compose.yml liegt
docker compose stop freshrss
```

Der Container ist gestoppt, die Daten in `./config/` sind konsistent.

### Schritt 2 — Hilfspod starten der das PVC mountet

Auf dem neuen Raspi (k3s):

> **fish-Hinweis:** `<<EOF` ist bash-Syntax. Kurz in bash wechseln:

```bash
bash   # kurz in bash wechseln

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: migration
  namespace: freshrss
spec:
  containers:
    - name: migration
      image: alpine
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: freshrss-config
EOF

exit   # zurück zu fish

kubectl wait --for=condition=Ready pod/migration -n freshrss --timeout=30s
```

### Schritt 3 — Daten übertragen

Von deinem Laptop (oder direkt vom alten Raspi):
```bash
# Vom Laptop aus: erst vom alten Raspi holen, dann in den Cluster
# (oder direkt vom alten Raspi wenn du dort eingeloggt bist)

# Option A: Laptop als Zwischenstation
rsync -av stefan@alter-raspi:~/docker/freshrss/config/ /tmp/freshrss-config/
kubectl cp /tmp/freshrss-config/. freshrss/migration:/config/

# Option B: Direkt vom alten Raspi in den Cluster (setzt kubectl-Zugriff auf altem Raspi voraus)
# rsync -av ./config/ stefan@raspi5:/tmp/freshrss-config/
# kubectl cp /tmp/freshrss-config/. freshrss/migration:/config/
```

Prüfen ob die Daten angekommen sind:
```bash
kubectl exec -n freshrss migration -- ls /config
# Sollte www/, log/ etc. zeigen — die FreshRSS-Verzeichnisstruktur
```

### Schritt 4 — Hilfspod entfernen

```bash
kubectl delete pod migration -n freshrss
```

FreshRSS-Deployment startet automatisch neu und findet die kopierten Daten.

### Schritt 5 — Testen (noch ohne nginx-Umschaltung)

```bash
kubectl port-forward -n freshrss deploy/freshrss 8080:80
```

`http://localhost:8080` → FreshRSS sollte mit deinen Feeds und Einstellungen erscheinen — kein Setup-Assistent, direkt eingeloggt.

---

## 7. nginx umleiten

Auf dem alten Raspi in deiner nginx-Konfiguration den `proxy_pass` für FreshRSS von `localhost:8080` auf den neuen Raspi umstellen:

```nginx
# vorher:
proxy_pass http://localhost:8080;

# nachher (IP des neuen Raspi 5):
proxy_pass http://192.168.1.100;   # Port 80, Traefik übernimmt das Routing
```

```bash
docker compose restart nginx   # oder wie du nginx neu lädst
```

Danach ist FreshRSS über deine gewohnte Domain erreichbar — jetzt aber aus k3s heraus.

---

## 8. Docker-Container entfernen

Wenn alles funktioniert:
```bash
# Auf dem alten Raspi
docker compose rm freshrss
# config/-Verzeichnis kann als Backup noch eine Weile bleiben
```

---

## 9. Troubleshooting

```bash
# Pod startet nicht?
kubectl describe pod -n freshrss -l app=freshrss
kubectl logs -n freshrss -l app=freshrss

# Ingress greift nicht?
kubectl describe ingress -n freshrss freshrss

# Longhorn Volume-Status
kubectl describe pvc -n freshrss freshrss-config
# → in der Longhorn UI nachschauen ob das Volume Attached ist

# FreshRSS zeigt falsche URLs (http statt https)?
# nginx muss X-Forwarded-Proto: https setzen — in proxy-headers.conf prüfen
```

---

## Weiter: [05 — Seafile deployen](./05-seafile.md)
