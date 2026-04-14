# Vaultwarden (Password Manager)

This document describes the concept and implementation of a self-hosted password manager based on Vaultwarden — including security architecture, backup strategy, and Tier-0 emergency plan.

> **Status:** Concept — Kubernetes deployment not yet implemented. YubiKeys procured and in use (SOPS + age).

---

## Why Vaultwarden instead of official Bitwarden Self-Hosted

The official Bitwarden server consists of ~7 Docker containers including Microsoft SQL Server — oversized for a homelab. Vaultwarden is a complete reimplementation of the Bitwarden Server API in Rust:

| | Bitwarden Self-Hosted | Vaultwarden |
|---|---|---|
| Language | C#/.NET | Rust |
| Containers | ~7 (incl. MSSQL) | 1 |
| RAM | ~2–4 GB | ~10–50 MB |
| Database | Microsoft SQL Server | SQLite |
| License | partially proprietary | MIT |
| SSO/OIDC | Enterprise feature | Community fork |

The official Bitwarden clients (browser extension, mobile apps, desktop, CLI) work fully against Vaultwarden — the server API is identical. Vaultwarden is used by hundreds of thousands of homelab operators and is considered mature.

---

## Encryption architecture (zero-knowledge)

Vaultwarden never sees unencrypted passwords. All encryption happens client-side:

```
Master password + email
    → PBKDF2-SHA256 (600,000 iterations, client-side)
        → Master Key (256 bit)
            → protects Account Symmetric Key (AES-CBC-256)
                → encrypts all vault entries (AES-CBC-256)
```

The server stores only encrypted blobs. Even full database access is worthless without the master password. The `rsa_key.pem` file in the data directory is used exclusively for JWT signing (session management) — it has no effect on data encryption and can be regenerated.

---

## Security architecture

### Public reachability

Vaultwarden is operated publicly (analogous to bitwarden.eu) — only this way is convenience guaranteed on all devices. The security layers:

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
    ├── Google SSO (OIDC) — primary login
    ├── YubiKey FIDO2 — 2FA
    └── Admin panel: only reachable via kubectl/CLI (no Ingress)
```

### Google SSO via OIDC

Vaultwarden itself does not support native SSO — that is an Enterprise feature of the official server. The community fork [Timshel/oidc_web_builds](https://github.com/Timshel/oidc_web_builds) implements OIDC fully and is actively maintained.

**Why Google SSO despite the dependency:**
- Google Auth provides brute-force protection, account-wide monitoring, and credential stuffing detection at infrastructure level
- Vaultwarden is publicly reachable — an external security layer makes sense
- Fallback: local admin access is always available via `kubectl exec` (analogous to Paperless/Immich)

**Fallback when Google is unreachable:**

```bash
# Temporarily re-enable local login
kubectl set env deployment/vaultwarden \
  -n vaultwarden \
  SSO_ONLY=false
```

### YubiKey as 2FA

The YubiKeys (procured anyway for Tier-0) also serve as FIDO2 tokens for the Vaultwarden login. A single physical device thus serves two purposes:
- 2FA for daily vault access
- Emergency decryption of Tier-0 credentials

### Disable registration

```
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=false
```

New accounts only via the admin panel — no public self-service.

---

## Kubernetes deployment

### Namespace and structure

```
Namespace: vaultwarden
  ├── Deployment: vaultwarden (Timshel OIDC fork)
  ├── Service: vaultwarden (ClusterIP)
  ├── PVC: vaultwarden-data (local-path)
  ├── vaultwarden-secrets.sops.yaml  (SOPS-encrypted Secret)
  │     ├── ADMIN_TOKEN
  │     ├── OIDC_CLIENT_ID (Google)
  │     ├── OIDC_CLIENT_SECRET (Google)
  │     └── SMTP_* (optional, for email notifications)
  └── IngressRoute: vault.example.com → Service vaultwarden
```

### Important environment variables

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
    value: "true"                    # local login disabled
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

Vaultwarden data on `local-path`:

```yaml
storageClassName: local-path
```

The `/data` directory contains:
```
/data/
    ├── db.sqlite3          # main database
    ├── db.sqlite3-wal      # write-ahead log (active during operation)
    ├── db.sqlite3-shm      # shared memory
    ├── attachments/        # file attachments
    ├── sends/              # Bitwarden Sends
    ├── config.json         # configuration
    └── rsa_key*            # JWT signing keys (can be regenerated)
```

---

## Backup strategy

### Concept: Bitwarden CLI from Pi1

The backup does not run on K8s, but is pulled from Pi1 (docker-runtime) by the existing backup script via the Bitwarden API. No SSH to Pi2, no `rsync`, no `docker exec` — the `bw` CLI behaves like a normal client:

```
Pi1 (backup script)
    └── bw config server https://vault.example.com
    └── bw login --apikey
    └── bw export --format encrypted_json
    └── restic backup → SSD + S3
```

**Why this approach:**
- Central backup script stays on Pi1 — no new infrastructure
- Consistent export without SQLite lock issues
- Encrypted JSON: readable without a running Vaultwarden server (only the export password is needed)
- Seamless integration into existing Restic setup (SSD + S3)

### Addition to backup.sh

New block in the existing `scripts/backup.sh`:

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

New variables in `.restic.env`:
```bash
VW_URL="https://vault.example.com"
VW_CLIENT_ID="..."        # Bitwarden API key client ID
VW_CLIENT_SECRET="..."    # Bitwarden API key client secret
VW_PASSWORD="..."         # master password (for bw unlock)
VW_EXPORT_PASSWORD="..."  # encryption password for the JSON export
```

### What the backup contains

The `encrypted_json` export contains all vault entries encrypted. It is readable without a running Vaultwarden server — only the `bw` CLI and the `VW_EXPORT_PASSWORD` are needed:

```bash
# Restore from export file (without Vaultwarden server)
bw import --format bitwardenencryptedJson vault_2026-03-28.json
```

**Not included in the export:** file attachments. These live in the local-path volume and are backed up via the regular Restic backup (→ [backup-restore.md](../operations/backup-restore.md)).

---

## Tier-0 emergency plan

### The bootstrap problem

The password manager secures the credentials needed to restore the password manager. To break this circular dependency, a small set of "Tier-0" secrets exists outside the vault.

### Tier-0 contents

A single encrypted file (`tier0.age`) with the absolute bootstrap credentials:

```
tier0.age
    ├── Restic repository password (SSD)
    ├── Restic repository password (S3)
    ├── S3 access key + secret
    ├── Vaultwarden master password
    ├── SOPS age private key
    └── RUNBOOK.md — step-by-step restore guide
```

Everything else (all further passwords, configurations, services) becomes accessible again once the password manager is restored.

### Encryption: Age with YubiKey (multiple recipients)

[Age](https://age-encryption.org) is a modern, simple encryption format. Via the `age-plugin-yubikey`, each YubiKey (PIV slot) can be added as a recipient — each key decrypts independently:

```bash
age -r yubikey1-public-key \
    -r yubikey2-public-key \
    -r yubikey3-public-key \
    tier0.md > tier0.age
```

The private key never leaves the YubiKey. Decryption requires:
1. Physical possession of the YubiKey
2. PIV PIN

### YubiKey distribution (3 keys)

| Key | Location | Scenario |
|---|---|---|
| Key 1 | Always with me | Daily use, quick access |
| Key 2 | Home (safe) | Key 1 lost or broken |
| Key 3 | Daughter (offsite) | Fire/burglary at home + emergency/death |

Simultaneous loss of all three keys is an unrealistic scenario (lost while out + fire at home + lost at daughter's).

### Storage of tier0.age

The file is encrypted — its storage location is not critical. Redundancy through two different ecosystems:

```
tier0.age
    ├── Proton Drive (Switzerland, zero-knowledge)
    └── Google Drive (redundancy, different ecosystem)
```

### Public restore runbook on GitHub

A public `RESTORE.md` in this repository — no login needed, no password manager needed:

```markdown
# Restore

1. tier0.age is located on: Proton Drive + Google Drive
2. Decrypt: install age-plugin-yubikey, plug in YubiKey
   age -d tier0.age > tier0.md
3. Detailed runbook: in tier0.md (section RUNBOOK)
```

The signpost is public. The actual guide is safely inside `tier0.age`.

### Restore order (from the runbook)

```
1. Decrypt tier0.age (YubiKey + PIN)
2. Restic credentials → mount backup on SSD/S3
3. Restore Vaultwarden export → bw import
4. All further credentials are now in the vault
5. Rebuild k3s cluster (→ docs/operations/backup-restore.md)
6. Restic restore of service volumes
7. Deploy services
```

**Vaultwarden must be running first** — only then are all other credentials for infrastructure recovery available.

---

## Open items / TODO

- [x] Procure YubiKeys — done, all 3 keys in use
- [x] Set up age-plugin-yubikey, configure PIV slots — done (SOPS encryption active)
- [ ] Create tier0.age and upload to Proton Drive + Google Drive
- [ ] Create RESTORE.md in this repo (public)
- [ ] Vaultwarden Kubernetes manifest (`apps/vaultwarden/vaultwarden.yaml`)
- [ ] Create Google OAuth2 client ID for Vaultwarden
- [ ] Create SOPS secret for Vaultwarden credentials (`apps/vaultwarden/vaultwarden-secrets.sops.yaml`)
- [ ] Add Vaultwarden block to backup.sh (docker-runtime repo)
- [ ] Add VW_* variables to `.restic.env.example`
