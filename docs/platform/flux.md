# GitOps with Flux CD

Prerequisite: [Install k3s](./k3s-install.md) and [SOPS + age](./sops.md) completed, cluster is running.

Flux monitors this Git repository and automatically deploys any change pushed to `main`. The cluster state always mirrors the repo state — no manual `kubectl apply` needed for managed services.

---

## Why Flux instead of ArgoCD?

- Lighter resource footprint (fits on a Raspi)
- Pull-based: no webhook needed, works behind NAT
- SOPS decryption built into `kustomize-controller` — no extra controller needed
- Native `HelmRelease` support → Renovate can track Helm chart versions automatically

---

## Step 1 — Create a GitHub App

Flux needs write access to the repo to commit its own manifests during bootstrap.

**Create a new GitHub App** under Settings → Developer Settings → GitHub Apps → New GitHub App:

| Field | Value |
|---|---|
| Name | `k3s-flux` (or similar) |
| Homepage URL | `https://github.com/Spiev/k3s` |
| Webhooks | disable |

**Repository Permissions:**

| Permission | Level |
|---|---|
| Contents | Read & write |
| Metadata | Read |

After creation:
1. Note the **App ID** (shown on the app page under "About")
2. Generate a **private key** (bottom of the app page) → save the `.pem` file in Vaultwarden
3. **Install the app** on the `k3s` repository (Settings → Install App)
4. Note the **Installation ID** from the URL after installation: `github.com/settings/installations/<INSTALLATION_ID>`

---

## Step 2 — Bootstrap Flux (on the Pi)

Copy the private key `.pem` to the Pi:

```bash
scp k3s-flux.pem stefan@k3s.fritz.box:~/.config/flux-github-app.pem
ssh stefan@k3s.fritz.box "chmod 600 ~/.config/flux-github-app.pem"
```

Install Flux CLI on the Pi:

```bash
ssh stefan@k3s.fritz.box "curl -s https://fluxcd.io/install.sh | sudo bash"
```

`flux bootstrap github` does not support GitHub App flags directly — a short-lived installation token must be generated first:

```bash
ssh stefan@k3s.fritz.box "
APP_ID=<APP_ID>
INSTALLATION_ID=<INSTALLATION_ID>
PEM=~/.config/flux-github-app.pem

NOW=\$(date +%s)
IAT=\$((NOW - 60))
EXP=\$((NOW + 600))
HEADER=\$(echo -n '{\"alg\":\"RS256\",\"typ\":\"JWT\"}' | base64 -w0 | tr -d '=' | tr '/+' '_-')
PAYLOAD=\$(echo -n \"{\\\"iat\\\":\${IAT},\\\"exp\\\":\${EXP},\\\"iss\\\":\\\"\${APP_ID}\\\"}\" | base64 -w0 | tr -d '=' | tr '/+' '_-')
SIG_INPUT=\"\${HEADER}.\${PAYLOAD}\"
SIG=\$(echo -n \"\$SIG_INPUT\" | openssl dgst -sha256 -sign \$PEM | base64 -w0 | tr -d '=' | tr '/+' '_-')
JWT=\"\${SIG_INPUT}.\${SIG}\"

TOKEN=\$(curl -s -X POST \
  -H \"Authorization: Bearer \$JWT\" \
  -H \"Accept: application/vnd.github+json\" \
  https://api.github.com/app/installations/\${INSTALLATION_ID}/access_tokens | jq -r '.token')

GITHUB_TOKEN=\$TOKEN flux bootstrap github \
  --owner=Spiev \
  --repository=k3s \
  --branch=main \
  --path=clusters/raspi \
  --token-auth \
  --personal
"
```

> **Branch Protection:** On personal GitHub accounts, bypass actors are not available. Temporarily disable the branch protection rule for `main` before running bootstrap, then re-enable it afterwards.

Flux:
1. Installs itself into the cluster (`flux-system` namespace)
2. Commits `clusters/raspi/flux-system/` to the repo
3. Starts watching the repo from that point on

Verify:

```bash
ssh stefan@k3s.fritz.box "flux check"
ssh stefan@k3s.fritz.box "KUBECONFIG=~/.kube/config kubectl get pods -n flux-system"
```

---

## Step 3 — Set up age keys for SOPS

Two keys are needed:
- **YubiKey age identity** — for local encryption/decryption on the laptop (hardware-bound, private key never leaves YubiKey)
- **Software age key** — for the cluster (Flux decrypts without a physical YubiKey)

### Prerequisites

```bash
# Arch Linux
sudo pacman -S age-plugin-yubikey yubikey-manager ccid pcsc-tools
sudo systemctl start pcscd
```

> **Note:** The YubiKey PIV PIN is **separate** from the FIDO2/WebAuthn PIN used for passkeys and Windows Hello. Default PIV PIN: `123456`, default PUK: `12345678`. Change both before use:
> ```bash
> ykman piv access change-pin
> ykman piv access change-puk
> ```
> Store both in Vaultwarden.

### Generate YubiKey age identity

```bash
age-plugin-yubikey --generate --slot 1 --pin-policy once --touch-policy cached
```

Note the public key (`age1yubikey1...`) — needed for `.sops.yaml`.

### Generate software age key (for cluster)

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Public key is shown in output: age1abc...
# Private key → back up to Vaultwarden immediately
```

### Update .sops.yaml

Add both public keys as recipients:

```yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1yubikey1...,
      age1abc...
```

Commit:

```bash
git add .sops.yaml
git commit -m "feat(sops): add age public keys (YubiKey + cluster)"
git push
```

### Bootstrap cluster key into flux-system

```bash
cat ~/.config/sops/age/keys.txt | \
  ssh stefan@k3s.fritz.box "KUBECONFIG=~/.kube/config kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin"
```

### Apply kustomize-controller SOPS patch

Create `infrastructure/flux/kustomize-controller-sops-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kustomize-controller
  namespace: flux-system
spec:
  template:
    spec:
      containers:
        - name: manager
          args:
            - --sops-age-secret=sops-age
```

Apply directly (or via Flux once infrastructure Kustomization exists):

```bash
ssh stefan@k3s.fritz.box "KUBECONFIG=~/.kube/config kubectl apply -f infrastructure/flux/kustomize-controller-sops-patch.yaml"
```

---

## Step 4 — Point Flux at the apps directory

Create `clusters/raspi/apps.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps
  prune: true
  wait: true
```

```bash
git add clusters/raspi/apps.yaml
git commit -m "feat(flux): add apps Kustomization"
git push
```

Flux picks this up within 1 minute and begins managing everything under `apps/`.

---

## Repository structure after bootstrap

```
clusters/raspi/
├── flux-system/          ← auto-generated by flux bootstrap (do not edit manually)
│   ├── gotk-components.yaml
│   ├── gotk-sync.yaml
│   └── kustomization.yaml
└── apps.yaml             ← points Flux at apps/

infrastructure/
└── flux/
    └── kustomize-controller-sops-patch.yaml   ← SOPS key config
```

---

## Traefik: move from k3s built-in to Flux HelmRelease (optional)

k3s ships Traefik as a built-in component — version tied to k3s, not trackable by Renovate. Moving it to a Flux `HelmRelease` enables independent version management.

> **Note:** This requires a short maintenance window — Traefik is briefly unavailable during the switchover.

**Step 1 — Disable built-in Traefik** on the Pi (`/etc/rancher/k3s/config.yaml`):

```yaml
disable:
  - traefik
```

```bash
sudo systemctl restart k3s
# Traefik pod is removed from the cluster
```

**Step 2 — Add Traefik as HelmRelease** (`infrastructure/traefik/helmrelease.yaml`):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: kube-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: kube-system
spec:
  interval: 1h
  chart:
    spec:
      chart: traefik
      version: "34.x.x"   # pin to current version, Renovate tracks this
      sourceRef:
        kind: HelmRepository
        name: traefik
```

**Step 3 — Add to Flux** via a `Kustomization` in `clusters/raspi/infrastructure.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure
  prune: true
```

Push → Flux deploys Traefik automatically within 1 minute.

> **Important:** Disable Traefik in k3s *before* deploying via Flux — otherwise CRD ownership conflicts occur.

---

## Verify Flux is managing everything

```bash
# Show all Flux Kustomizations and their sync status
ssh stefan@k3s.fritz.box "flux get kustomizations"

# Show all HelmReleases
ssh stefan@k3s.fritz.box "flux get helmreleases -A"

# Force a manual reconciliation
ssh stefan@k3s.fritz.box "flux reconcile kustomization flux-system --with-source"

# Watch Flux logs
ssh stefan@k3s.fritz.box "flux logs --follow"
```

---

## Next: [Deploy Seafile](../services/seafile.md)
