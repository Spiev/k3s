# 05 — Sealed Secrets einrichten

Voraussetzung: [04 — Longhorn](./04-longhorn.md) abgeschlossen.

Sealed Secrets löst zwei Probleme gleichzeitig:
- **Öffentliches Repo**: verschlüsselte Secrets können sicher committed werden — nur der Cluster kann sie entschlüsseln
- **Disaster Recovery**: `kubectl apply -f apps/<service>/` deployed alle Secrets automatisch mit, kein manuelles Wiederherstellen

---

## Schritt 1 — Controller im Cluster installieren

```bash
# Aktuelle Version prüfen: https://github.com/bitnami-labs/sealed-secrets/releases
SEALED_SECRETS_VERSION="v0.27.1"

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml
```

> **GitOps-Hinweis:** Das Laden des Manifests direkt aus dem Internet ist für den manuellen Setup-Schritt pragmatisch in Ordnung. Sobald Flux CD eingerichtet ist, gehört `controller.yaml` ins Repo (`infrastructure/sealed-secrets/controller.yaml`) — dann deployed Flux es deterministisch aus dem Repo, kein Internetzugriff beim Deploy nötig, und Renovate kann Updates als PR vorschlagen.

Controller-Status prüfen:
```bash
kubectl get pods -n kube-system -l name=sealed-secrets-controller -w
# Warten bis 1/1 Running
```

---

## Schritt 2 — kubeseal CLI auf dem Laptop installieren

kubeseal läuft auf dem **Laptop** (nicht auf dem Pi) — dort wo du Secrets erstellst und ins Repo committed.

```bash
# Arch Linux (x86_64)
SEALED_SECRETS_VERSION="v0.27.1"
KUBESEAL_VERSION="${SEALED_SECRETS_VERSION#v}"   # ohne führendes "v"

curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar xz kubeseal

sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal

# Prüfen
kubeseal --version
```

> Alternativ über AUR: `paru -S kubeseal` oder `yay -S kubeseal`

---

## Schritt 3 — Schlüssel SOFORT sichern

Der Controller generiert beim ersten Start ein asymmetrisches Schlüsselpaar. **Dieses Schlüsselpaar ist der einzige Weg, bestehende SealedSecrets zu entschlüsseln.** Geht es verloren, sind alle Sealed Secrets im Repo wertlos.

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.yaml
```

**Im Passwortmanager ablegen. Nicht ins Repo committen.**

Prüfen ob die Datei Inhalt hat:
```bash
grep "tls.crt" sealed-secrets-key.yaml
# → Sollte eine lange base64-Zeile zeigen
```

Danach die lokale Datei löschen:
```bash
rm sealed-secrets-key.yaml
```

---

## Schritt 4 — Erstes SealedSecret erstellen (Beispiel: Pi-hole)

Der Workflow ist immer gleich: Plain Secret auf stdout erzeugen → durch kubeseal pipen → SealedSecret ins Repo schreiben.

```bash
# 1. SealedSecret erzeugen (ersetze <dein-passwort>)
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=FTLCONF_webserver_api_password="<dein-passwort>" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/pihole/pihole-sealed-secret.yaml

# 2. Prüfen: die Datei enthält verschlüsselte Daten, kein Klartext
cat apps/pihole/pihole-sealed-secret.yaml
# → spec.encryptedData.WEBPASSWORD ist ein langer base64-String — kein Passwort sichtbar

# 3. In den Cluster deployen
kubectl apply -f apps/pihole/pihole-sealed-secret.yaml

# 4. Prüfen ob das echte Secret erzeugt wurde
kubectl get secret pihole-secret -n pihole
```

Die `pihole-sealed-secret.yaml` kann sicher ins Repo committed werden:
```bash
git add apps/pihole/pihole-sealed-secret.yaml
git commit -m "feat(pihole): add sealed secret for admin password"
```

> **Namespace-Bindung:** SealedSecrets sind standardmäßig an Namespace + Name gebunden. Ein SealedSecret für `namespace: pihole` lässt sich nicht in einem anderen Namespace entschlüsseln — das ist gewollt.

---

## Schritt 5 — .gitignore anpassen

Die alten Plain-Secret-Dateien können jetzt aus der `.gitignore` entfernt werden — oder bleiben drin als Sicherheitsnetz. Das `*-sealed-secret.yaml` hingegen gehört **ins Repo**:

```bash
# apps/pihole/.gitignore — pihole-secret.yaml bleibt gitignored (lokales Arbeitsfile)
# pihole-sealed-secret.yaml wird NICHT gitignored → committen
```

---

## Recovery nach Cluster-Neuinstall

**Reihenfolge ist kritisch:** Der alte Schlüssel muss eingelesen sein, bevor Services mit SealedSecrets deployed werden. Sonst generiert der Controller einen neuen Schlüssel und alle bestehenden SealedSecrets sind nicht mehr entschlüsselbar.

### 1. Controller installieren

```bash
SEALED_SECRETS_VERSION="v0.27.1"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml
```

### 2. Alten Schlüssel einspielen (VOR dem ersten Service-Deploy!)

Den Schlüssel aus dem Passwortmanager holen und in eine temporäre Datei speichern:

```bash
# Schlüssel einspielen
kubectl apply -f sealed-secrets-key.yaml

# Controller neu starten damit er den importierten Key lädt
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
kubectl rollout status deployment sealed-secrets-controller -n kube-system
# Warten bis "successfully rolled out"

# Temporäre Datei löschen
rm sealed-secrets-key.yaml
```

### 3. Verifizieren

```bash
# Prüfen: Controller nutzt den importierten Key (nicht einen neuen)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key
# → Erstellungsdatum des Keys sollte aus der Vergangenheit stammen (nicht "just now")
```

### 4. Services deployen

Erst jetzt `kubectl apply -f apps/<service>/` — die SealedSecrets werden automatisch entschlüsselt.

---

## Weiter: [Pi-hole deployen](../services/pihole.md)
