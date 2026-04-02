# Renovate (automatische Dependency-Updates)

Renovate überwacht alle gepinnten Versionen im Repo (Container-Images, GitHub Actions) und erstellt automatisch PRs wenn Updates verfügbar sind. Minor- und Patch-Updates werden automatisch gemergt, Major-Updates erfordern manuelle Bestätigung.

---

## Setup: GitHub App

Renovate läuft als selbst-gehostete GitHub App (via `renovatebot/github-action`). Kein Mend-Account nötig.

**GitHub App anlegen** unter Settings → Developer Settings → GitHub Apps → New GitHub App:

| Feld | Wert |
|---|---|
| Name | `Renovate - <repo-name>` |
| Homepage URL | URL des Repos |
| Webhooks | deaktivieren |
| **Repository permissions** | Contents: Read & Write, Issues: Read & Write, Pull requests: Read & Write, Workflows: Read & Write |
| **Repository permissions** | Dependabot alerts: Read-only (`vulnerability_alerts` intern) |
| **Where can this be installed** | Only on this account |

Nach dem Anlegen: App auf dem Repo installieren (Settings → Applications → Configure).

**Secrets im Repo** (Settings → Secrets → Actions):
- `RENOVATE_APP_ID` — App-ID (auf der App-Seite unter "About")
- `RENOVATE_APP_PRIVATE_KEY` — Private Key generieren und vollständig (inkl. Header/Footer) als Secret speichern

> **Wichtig:** Neue Berechtigungen einer bestehenden App werden erst aktiv nachdem die Installation neu genehmigt wurde: Settings → Applications → deine App → "Review and accept new permissions".

---

## Workflow

`.github/workflows/renovate.yml`:

```yaml
name: Renovate

on:
  schedule:
    # Runs daily at 03:00 Europe/Berlin (= 02:00 UTC)
    - cron: "0 2 * * *"
  workflow_dispatch: # allow manual trigger

permissions:
  contents: read

jobs:
  renovate:
    runs-on: ubuntu-latest
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@... # pin version
        with:
          app-id: ${{ secrets.RENOVATE_APP_ID }}
          private-key: ${{ secrets.RENOVATE_APP_PRIVATE_KEY }}

      - name: Run Renovate
        uses: renovatebot/github-action@... # pin version
        with:
          token: ${{ steps.app-token.outputs.token }}
        env:
          RENOVATE_AUTODISCOVER: "true"
```

> **Kein `actions/checkout`** — Renovate erledigt alle git-Operationen selbst über den API-Token.
>
> **Kein `schedule` in `renovate.json`** — der interne Renovate-Schedule würde auch `workflow_dispatch`-Runs blockieren. Die Cron-Zeit im Workflow-File reicht.

---

## Konfiguration

`.github/renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "enabledManagers": ["github-actions", "kubernetes"],
  "kubernetes": {
    "fileMatch": ["apps/.+\\.yaml$", "infrastructure/.+\\.yaml$"]
  },
  "dependencyDashboard": false,
  "packageRules": [
    {
      "description": "LinuxServer.io images use 1.x.y-lsNNN versioning — regex extracts build number for correct comparison",
      "matchPackagePrefixes": ["lscr.io/linuxserver/"],
      "versioning": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-ls(?<build>\\d+)$"
    },
    {
      "description": "Auto-merge minor and patch updates",
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true,
      "automergeType": "pr"
    },
    {
      "description": "Major updates require manual review",
      "matchUpdateTypes": ["major"],
      "automerge": false
    }
  ]
}
```

### Wichtige Konfigurationsentscheidungen

**`enabledManagers` mit explizitem `fileMatch`**

Der `kubernetes`-Manager hat standardmäßig `fileMatch: []` — er scannt ohne explizite Konfiguration keine einzige Datei. `enabledManagers` aktiviert den Manager nur; wo er sucht, muss immer explizit angegeben werden.

**LinuxServer.io: regex statt loose versioning**

LinuxServer.io-Images (`lscr.io/linuxserver/*`) verwenden das Format `1.28.1-ls299`. Mit `loose` versioning behandelt Renovate den `-ls299`-Suffix als semver-Pre-release und schlägt vor, auf den "stabilen" Bare-Tag `1.28.1` zu wechseln — falsch. Das `regex`-Pattern extrahiert `major`, `minor`, `patch` und `build` (die `ls`-Nummer) separat, sodass `ls299 > ls298` korrekt verglichen wird.

---

## Digest Pinning

Mit `"pinDigests": true` ergänzt Renovate jeden Image-Tag um den SHA256-Digest:

```yaml
# vorher
image: lscr.io/linuxserver/freshrss:1.28.1-ls299

# nachher (Renovate-PR)
image: lscr.io/linuxserver/freshrss:1.28.1-ls299@sha256:3f2a1b...
```

Kubernetes verwendet dann ausschließlich den Digest zum Pullen — der Tag bleibt nur zur Lesbarkeit erhalten. Das schützt gegen Tag-Mutability: ein Registry-Betreiber könnte theoretisch denselben Tag auf ein anderes Image pushen, der Digest bleibt dagegen unveränderlich.

Renovate trackt zwei Update-Typen:

| Update-Typ | Wann | Beispiel |
|---|---|---|
| `patch` / `minor` | Neuer Tag verfügbar | `ls299` → `ls300` |
| `digest` | Neuer SHA256 beim selben Tag | Base-Image-Patch ohne neuen Tag |

**Wichtig:** Digest-Updates haben einen eigenen `updateType: "digest"` — dieser muss explizit in der Automerge-Regel stehen, sonst werden Digest-PRs nicht automatisch gemergt:

```json
"matchUpdateTypes": ["minor", "patch", "digest"]
```

---

## Debugging

Wenn Renovate keinen PR erstellt, zuerst Debug-Logging aktivieren (temporär):

```yaml
env:
  RENOVATE_AUTODISCOVER: "true"
  LOG_LEVEL: "debug"
```

Im Log nach folgenden Stellen suchen:

| Was suchen | Bedeutung |
|---|---|
| `"managers": {...}` | Zeigt welche Manager liefen und wie viele Dateien/Deps gefunden wurden |
| `Package not scheduled` | Interner Schedule blockiert den Run → Schedule aus `renovate.json` entfernen |
| `newVersion` / `newValue` | Zeigt das vorgeschlagene Update — prüfen ob es korrekt ist |
| `kubernetes` fehlt in managers | `fileMatch` fehlt oder falsch konfiguriert |

Nach dem Debugging `LOG_LEVEL: "debug"` wieder entfernen.

---

## Pitfalls-Übersicht

| Problem | Ursache | Fix |
|---|---|---|
| "No repositories found" | `RENOVATE_AUTODISCOVER` fehlt | `RENOVATE_AUTODISCOVER: "true"` setzen |
| Kubernetes-Manifests werden nicht gescannt | `fileMatch: []` default | Explizites `fileMatch` in `kubernetes`-Config |
| Falsches Update (Suffix wird entfernt) | `loose` versioning für LinuxServer.io | `regex` versioning mit `ls`-Pattern |
| `workflow_dispatch` erstellt keine PRs | Schedule in `renovate.json` | Schedule aus `renovate.json` entfernen |
| GitHub App Permissions greifen nicht | Neue Permissions nicht re-approved | App-Installation neu genehmigen |
