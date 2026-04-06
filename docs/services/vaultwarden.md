# Vaultwarden (Password Manager)

Dieses Dokument beschreibt das Konzept und die Umsetzung eines selbst gehosteten Passwort-Managers auf Basis von Vaultwarden — inklusive Sicherheitsarchitektur, Backup-Strategie und Tier-0-Notfallkonzept.

> **Status:** Konzept — noch nicht umgesetzt. YubiKeys werden beschafft.

---

## Warum Vaultwarden statt offiziell Bitwarden Self-Hosted

Der offizielle Bitwarden Server besteht aus ~7 Docker-Containern inklusive Microsoft SQL Server — für ein Homelab überdimensioniert. Vaultwarden ist eine vollständige Neuimplementierung der Bitwarden Server API in Rust:

| | Bitwarden Self-Hosted | Vaultwarden |
|---|---|---|
| Sprache | C#/.NET | Rust |
| Container | ~7 (inkl. MSSQL) | 1 |
| RAM | ~2–4 GB | ~10–50 MB |
| Datenbank | Microsoft SQL Server | SQLite |
| Lizenz | teilweise proprietär | MIT |
| SSO/OIDC | Enterprise-Feature | Community-Fork |

Die offiziellen Bitwarden-Clients (Browser-Extension, Mobile-Apps, Desktop, CLI) funktionieren vollständig gegen Vaultwarden — die Server-API ist identisch. Vaultwarden ist bei hunderttausenden Homelab-Betreibern im Einsatz und gilt als ausgereift.

---

## Verschlüsselungsarchitektur (Zero-Knowledge)

Vaultwarden sieht niemals unverschlüsselte Passwörter. Die gesamte Verschlüsselung findet clientseitig statt:

```
Master-Passwort + E-Mail
    → PBKDF2-SHA256 (600.000 Iterationen, clientseitig)
        → Master Key (256 Bit)
            → schützt Account Symmetric Key (AES-CBC-256)
                → verschlüsselt alle Tresor-Einträge (AES-CBC-256)
```

Der Server speichert ausschließlich verschlüsselte Blobs. Selbst ein vollständiger Datenbankzugriff ist ohne das Master-Passwort wertlos. Die `rsa_key.pem`-Datei im Datenverzeichnis dient ausschließlich der JWT-Signierung (Session-Management) — sie hat keinen Einfluss auf die Datenverschlüsselung und ist neu generierbar.

---

## Sicherheitsarchitektur

### Öffentliche Erreichbarkeit

Vaultwarden wird öffentlich betrieben (analog zu bitwarden.eu) — nur so ist der Komfort auf allen Geräten gewährleistet. Die Sicherheitsschichten:

```
Internet
    │
    ▼
nginx / Traefik
    ├── TLS (Let's Encrypt)
    ├── Rate Limiting
    └── Fail2ban
    │
    ▼
Vaultwarden (k3s, Agent-Node)
    ├── Google SSO (OIDC) — primärer Login
    ├── YubiKey FIDO2 — 2FA
    └── Admin-Panel: nur per kubectl/CLI erreichbar (kein Ingress)
```

### Google SSO via OIDC

Vaultwarden selbst unterstützt kein natives SSO — das ist ein Enterprise-Feature des offiziellen Servers. Der Community-Fork [Timshel/oidc_web_builds](https://github.com/Timshel/oidc_web_builds) implementiert OIDC vollständig und wird aktiv gepflegt.

**Warum Google SSO trotz Abhängigkeit:**
- Google-Auth bietet Brute-Force-Schutz, Account-weites Monitoring und Credential-Stuffing-Erkennung auf Infrastruktur-Ebene
- Vaultwarden ist öffentlich erreichbar — externe Sicherheitsschicht ist sinnvoll
- Fallback: lokaler Admin-Zugang bleibt immer per `kubectl exec` erreichbar (analog zu Paperless/Immich)

**Fallback wenn Google nicht erreichbar ist:**

```bash
# Lokalen Login temporär reaktivieren
kubectl set env deployment/vaultwarden \
  -n vaultwarden \
  SSO_ONLY=false
```

### YubiKey als 2FA

Die YubiKeys (ohnehin für Tier-0 beschafft) dienen gleichzeitig als FIDO2-Token für den Vaultwarden-Login. Ein einziges physisches Gerät erfüllt damit zwei Aufgaben:
- 2FA für den täglichen Vault-Zugriff
- Notfall-Entschlüsselung der Tier-0-Credentials

### Registrierung deaktivieren

```
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=false
```

Neue Accounts nur über den Admin-Panel anlegen — kein öffentlicher Self-Service.

---

## Kubernetes-Deployment

### Namespace und Grundstruktur

```
Namespace: vaultwarden
  ├── Deployment: vaultwarden (Timshel OIDC-Fork)
  ├── Service: vaultwarden (ClusterIP)
  ├── PVC: vaultwarden-data (local-path)
  ├── SealedSecret: vaultwarden-secrets
  │     ├── ADMIN_TOKEN
  │     ├── OIDC_CLIENT_ID (Google)
  │     ├── OIDC_CLIENT_SECRET (Google)
  │     └── SMTP_* (optional, für E-Mail-Benachrichtigungen)
  └── IngressRoute: vault.example.com → Service vaultwarden
```

### Wichtige Umgebungsvariablen

```yaml
env:
  - name: DOMAIN
    value: "https://vault.example.com"
  - name: SIGNUPS_ALLOWED
    value: "false"
  - name: INVITATIONS_ALLOWED
    value: "false"
  - name: SSO_ENABLED
    value: "true"
  - name: SSO_ONLY
    value: "true"                    # lokaler Login deaktiviert
  - name: SSO_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: vaultwarden-secrets
        key: OIDC_CLIENT_ID
  - name: SSO_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: vaultwarden-secrets
        key: OIDC_CLIENT_SECRET
  - name: SSO_AUTHORITY
    value: "https://accounts.google.com"
  - name: ADMIN_TOKEN
    valueFrom:
      secretKeyRef:
        name: vaultwarden-secrets
        key: ADMIN_TOKEN
```

### Storage

Vaultwarden-Daten auf `local-path`:

```yaml
storageClassName: local-path
```

Das `/data`-Verzeichnis enthält:
```
/data/
    ├── db.sqlite3          # Hauptdatenbank
    ├── db.sqlite3-wal      # Write-Ahead-Log (aktiv während Betrieb)
    ├── db.sqlite3-shm      # Shared Memory
    ├── attachments/        # Dateianhänge
    ├── sends/              # Bitwarden Sends
    ├── config.json         # Konfiguration
    └── rsa_key*            # JWT-Signing-Keys (neu generierbar)
```

---

## Backup-Strategie

### Konzept: Bitwarden CLI von Pi1

Das Backup läuft nicht auf K8s, sondern wird vom bestehenden Backup-Script auf Pi1 (docker-runtime) über die Bitwarden-API gezogen. Kein SSH zu Pi2, kein `rsync`, kein `docker exec` — der `bw`-CLI verhält sich wie ein normaler Client:

```
Pi1 (Backup-Script)
    └── bw config server https://vault.example.com
    └── bw login --apikey
    └── bw export --format encrypted_json
    └── restic backup → SSD + S3
```

**Warum dieser Ansatz:**
- Zentrales Backup-Script bleibt auf Pi1 — keine neue Infrastruktur
- Konsistenter Export ohne SQLite-Lock-Probleme
- Encrypted JSON: lesbar ohne laufenden Vaultwarden-Server (nur Export-Passwort nötig)
- Nahtlose Integration in bestehendes Restic-Setup (SSD + S3)

### Ergänzung zum backup.sh

Neuer Block im bestehenden `scripts/backup.sh`:

```bash
# ============================================================================
# Backup Vaultwarden (via Bitwarden CLI)
# ============================================================================

echo "Starting Vaultwarden Backup"

VW_EXPORT_DIR="$DOCKER_BASE/vaultwarden/backup"
mkdir -p "$VW_EXPORT_DIR"

export BW_CLIENTID="$VW_CLIENT_ID"
export BW_CLIENTSECRET="$VW_CLIENT_SECRET"

bw config server "$VW_URL"
bw login --apikey

BW_SESSION=$(bw unlock --passwordenv VW_PASSWORD --raw)

bw export \
  --format encrypted_json \
  --password "$VW_EXPORT_PASSWORD" \
  --output "$VW_EXPORT_DIR/vault_$(date +%Y-%m-%d).json" \
  --session "$BW_SESSION"

bw logout

VAULTWARDEN_OUTPUT=$(restic -r "$RESTIC_REPO" backup "$VW_EXPORT_DIR" \
  --tag vaultwarden --verbose 2>&1)
echo "$VAULTWARDEN_OUTPUT"
```

Neue Variablen in `.restic.env`:
```bash
VW_URL="https://vault.example.com"
VW_CLIENT_ID="..."        # Bitwarden API Key Client ID
VW_CLIENT_SECRET="..."    # Bitwarden API Key Client Secret
VW_PASSWORD="..."         # Master-Passwort (für bw unlock)
VW_EXPORT_PASSWORD="..."  # Verschlüsselungspasswort für den JSON-Export
```

### Was das Backup enthält

Der `encrypted_json`-Export enthält alle Vault-Einträge verschlüsselt. Er ist ohne laufenden Vaultwarden-Server lesbar — nur der `bw`-CLI und das `VW_EXPORT_PASSWORD` werden benötigt:

```bash
# Restore aus Export-Datei (ohne Vaultwarden-Server)
bw import --format bitwardenencryptedJson vault_2026-03-28.json
```

**Nicht im Export enthalten:** Dateianhänge (Attachments). Diese liegen im local-path-Volume und werden über das reguläre Restic-Backup gesichert (→ [backup-restore.md](../operations/backup-restore.md)).

---

## Tier-0 Notfall-Konzept

### Das Bootstrap-Problem

Der Passwort-Manager sichert die Credentials die man braucht um den Passwort-Manager wiederherzustellen. Um diesen Zirkel zu durchbrechen, existiert eine kleine Menge an "Tier-0"-Secrets außerhalb des Vaults.

### Tier-0 Inhalt

Eine einzige verschlüsselte Datei (`tier0.age`) mit den absoluten Bootstrap-Credentials:

```
tier0.age
    ├── Restic Repository Passwort (SSD)
    ├── Restic Repository Passwort (S3)
    ├── S3 Access Key + Secret
    ├── Vaultwarden Master-Passwort
    ├── Sealed Secrets Key (YAML)
    └── RUNBOOK.md — Schritt-für-Schritt Restore-Anleitung
```

Alles andere (alle weiteren Passwörter, Konfigurationen, Services) ist nach dem Restore des Passwort-Managers wieder zugänglich.

### Verschlüsselung: Age mit YubiKey (Multiple Recipients)

[Age](https://age-encryption.org) ist ein modernes, simples Verschlüsselungsformat. Über das `age-plugin-yubikey` kann jeder YubiKey (PIV-Slot) als Empfänger eingetragen werden — jeder Key entschlüsselt unabhängig:

```bash
age -r yubikey1-public-key \
    -r yubikey2-public-key \
    -r yubikey3-public-key \
    tier0.md > tier0.age
```

Der Private Key verlässt den YubiKey dabei nie. Entschlüsseln erfordert:
1. Physischen Besitz des YubiKeys
2. PIV-PIN

### YubiKey-Verteilung (3 Keys)

| Key | Aufbewahrung | Szenario |
|---|---|---|
| Key 1 | Immer dabei | Tägliche Nutzung, schneller Zugriff |
| Key 2 | Zuhause (Tresor) | Key 1 verloren oder defekt |
| Key 3 | Tochter (extern) | Brand/Einbruch zuhause + Notfall/Todesfall |

Der gleichzeitige Verlust aller drei Keys ist ein unrealistisches Szenario (Verlust unterwegs + Brand zuhause + Verlust bei Tochter).

### Storage der tier0.age

Die Datei ist verschlüsselt — ihr Ablageort ist unkritisch. Redundanz durch zwei verschiedene Ökosysteme:

```
tier0.age
    ├── Proton Drive (Schweiz, Zero-Knowledge)
    └── Google Drive (Redundanz, anderes Ökosystem)
```

### Öffentliches Restore-Runbook auf GitHub

Ein öffentliches `RESTORE.md` in diesem Repository — kein Login nötig, kein Passwort-Manager nötig:

```markdown
# Restore

1. tier0.age liegt auf: Proton Drive + Google Drive
2. Entschlüsseln: age-plugin-yubikey installieren, YubiKey einstecken
   age -d tier0.age > tier0.md
3. Detailliertes Runbook: in tier0.md (Abschnitt RUNBOOK)
```

Der Wegweiser ist public. Die eigentliche Anleitung liegt sicher in `tier0.age`.

### Restore-Reihenfolge (aus dem Runbook)

```
1. tier0.age entschlüsseln (YubiKey + PIN)
2. Restic-Credentials → Backup auf SSD/S3 mounten
3. Vaultwarden-Export wiederherstellen → bw import
4. Alle weiteren Credentials sind jetzt im Vault verfügbar
5. K3s-Cluster neu aufsetzen (→ docs/operations/backup-restore.md)
6. Restic-Restore der Service-Volumes
7. Services deployen
```

**Vaultwarden muss als erstes laufen** — erst dann sind alle anderen Credentials für die Infrastruktur-Wiederherstellung zugänglich.

---

## Offene Punkte / TODO

- [ ] YubiKeys beschaffen (2 weitere, 1 vorhanden)
- [ ] age-plugin-yubikey einrichten, PIV-Slots konfigurieren
- [ ] tier0.age erstellen und auf Proton Drive + Google Drive ablegen
- [ ] RESTORE.md in diesem Repo erstellen (public)
- [ ] Vaultwarden Kubernetes-Manifest (`apps/vaultwarden/vaultwarden.yaml`)
- [ ] Google OAuth2 Client-ID für Vaultwarden anlegen
- [ ] SealedSecret für Vaultwarden-Credentials erstellen
- [ ] backup.sh um Vaultwarden-Block ergänzen (docker-runtime Repo)
- [ ] `.restic.env.example` um VW_*-Variablen ergänzen
