# Renovate (automated dependency updates)

Renovate monitors all pinned versions in the repo (container images, GitHub Actions) and automatically creates PRs when updates are available. Minor and patch updates are auto-merged; major updates require manual confirmation.

---

## Setup: GitHub App

Renovate runs as a self-hosted GitHub App (via `renovatebot/github-action`). No Mend account required.

**Create a GitHub App** under Settings → Developer Settings → GitHub Apps → New GitHub App:

| Field | Value |
|---|---|
| Name | `Renovate - <repo-name>` |
| Homepage URL | URL of the repo |
| Webhooks | disable |
| **Repository permissions** | Contents: Read & Write, Issues: Read & Write, Pull requests: Read & Write, Workflows: Read & Write |
| **Repository permissions** | Dependabot alerts: Read-only (`vulnerability_alerts` internally) |
| **Where can this be installed** | Only on this account |

After creation: install the app on the repo (Settings → Applications → Configure).

**Secrets in the repo** (Settings → Secrets → Actions):
- `RENOVATE_APP_ID` — App ID (on the app page under "About")
- `RENOVATE_APP_PRIVATE_KEY` — generate a private key and save it in full (including header/footer) as a secret

> **Important:** New permissions on an existing app only take effect after the installation is re-approved: Settings → Applications → your app → "Review and accept new permissions".

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

> **No `actions/checkout`** — Renovate handles all git operations itself via the API token.
>
> **No `schedule` in `renovate.json`** — the internal Renovate schedule would also block `workflow_dispatch` runs. The cron time in the workflow file is sufficient.

---

## Configuration

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

### Key configuration decisions

**`enabledManagers` with explicit `fileMatch`**

The `kubernetes` manager has `fileMatch: []` by default — without explicit configuration it does not scan a single file. `enabledManagers` only activates the manager; where it looks must always be specified explicitly.

**LinuxServer.io: regex instead of loose versioning**

LinuxServer.io images (`lscr.io/linuxserver/*`) use the format `1.28.1-ls299`. With `loose` versioning, Renovate treats the `-ls299` suffix as a semver pre-release and suggests switching to the "stable" bare tag `1.28.1` — which is wrong. The `regex` pattern extracts `major`, `minor`, `patch`, and `build` (the `ls` number) separately, so `ls299 > ls298` is compared correctly.

---

## Digest Pinning

With `"pinDigests": true`, Renovate appends the SHA256 digest to every image tag:

```yaml
# before
image: lscr.io/linuxserver/freshrss:1.28.1-ls299

# after (Renovate PR)
image: lscr.io/linuxserver/freshrss:1.28.1-ls299@sha256:3f2a1b...
```

Kubernetes then uses exclusively the digest to pull — the tag is kept only for readability. This protects against tag mutability: a registry operator could theoretically push a different image to the same tag, while the digest remains immutable.

Renovate tracks two update types:

| Update type | When | Example |
|---|---|---|
| `patch` / `minor` | New tag available | `ls299` → `ls300` |
| `digest` | New SHA256 for the same tag | Base image patch without a new tag |

**Important:** Digest updates have their own `updateType: "digest"` — this must be explicitly listed in the automerge rule, otherwise digest PRs are not auto-merged:

```json
"matchUpdateTypes": ["minor", "patch", "digest"]
```

---

## Debugging

If Renovate does not create a PR, first enable debug logging (temporarily):

```yaml
env:
  RENOVATE_AUTODISCOVER: "true"
  LOG_LEVEL: "debug"
```

Look for these entries in the log:

| What to search for | Meaning |
|---|---|
| `"managers": {...}` | Shows which managers ran and how many files/deps were found |
| `Package not scheduled` | Internal schedule is blocking the run → remove schedule from `renovate.json` |
| `newVersion` / `newValue` | Shows the proposed update — verify it is correct |
| `kubernetes` missing in managers | `fileMatch` is missing or misconfigured |

Remove `LOG_LEVEL: "debug"` after debugging.

---

## Pitfalls overview

| Problem | Cause | Fix |
|---|---|---|
| "No repositories found" | `RENOVATE_AUTODISCOVER` missing | Set `RENOVATE_AUTODISCOVER: "true"` |
| Kubernetes manifests not scanned | `fileMatch: []` default | Explicit `fileMatch` in `kubernetes` config |
| Wrong update (suffix removed) | `loose` versioning for LinuxServer.io | `regex` versioning with `ls` pattern |
| `workflow_dispatch` creates no PRs | Schedule in `renovate.json` | Remove schedule from `renovate.json` |
| GitHub App permissions not working | New permissions not re-approved | Re-approve the app installation |
