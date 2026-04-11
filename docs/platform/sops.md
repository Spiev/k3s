# Secret Management with SOPS + age

Prerequisite: [MetalLB](./metallb.md) completed, cluster is running.

SOPS (Secrets OPerationS) + age is the chosen secret management approach for this repo. Secrets are encrypted at the value level — key names stay visible in Git, only values are ciphertext. Flux CD decrypts them natively in memory before applying, so no extra controller is needed.

---

## Why SOPS + age instead of Sealed Secrets

| | Sealed Secrets | SOPS + age |
|---|---|---|
| Extra controller | Yes | No — built into Flux |
| Encrypt without cluster | No | Yes — only needs public key |
| Git diff readability | Opaque blob | Key names visible, values encrypted |
| Ordering problem (secret before deployment) | Requires `dependsOn` | Solved — Flux applies atomically |
| Transferable knowledge | Kubernetes-only | Used across Terraform, Ansible, Helm, any file |
| YubiKey support | No | Yes (local editing) |

---

## How it works

SOPS encrypts only the `data` and `stringData` fields of a Kubernetes Secret manifest. The result is a standard YAML file that is safe to commit to a public repo:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pihole-secret
  namespace: pihole
data:
  FTLCONF_webserver_api_password: ENC[AES256_GCM,data:abc123...,type:str]
sops:
  age:
    - recipient: age1abc...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
  version: 3.12.2
```

Flux's `kustomize-controller` decrypts this in memory during reconciliation and applies the plain `Secret` to the cluster — the decrypted value never touches disk or Git.

---

## Step 1 — Install tools (on the laptop)

```bash
# Arch Linux
sudo pacman -S age sops

# Or download sops binary manually (ARM64 if needed):
# https://github.com/getsops/sops/releases → sops-v3.x.x.linux.amd64
```

---

## Step 2 — Generate age key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Output: Public key: age1abc...  ← safe to share and commit
#         Private key written to: ~/.config/sops/age/keys.txt  ← NEVER commit this
```

**Back up the private key immediately** — store it in Vaultwarden. If it is lost, all encrypted secrets in Git become permanently unreadable.

---

## Step 3 — Update .sops.yaml in the repo

Replace the placeholder in `.sops.yaml` at the repo root with your actual public key:

```yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1abc...  # your actual public key
```

> Only files matching `*.sops.yaml` are encrypted — plain `*.yaml` files are left untouched. This makes it clear at a glance which files contain secrets.

Commit `.sops.yaml` — the public key is safe to share:
```bash
git add .sops.yaml
git commit -m "feat(sops): add encryption config with age public key"
```

---

## Step 4 — Bootstrap the age key into the cluster (one-time, manual)

This is the one step that cannot be automated from Git. The private key must exist in the cluster before Flux can decrypt anything. Do this once, right after `flux bootstrap`:

```bash
cat ~/.config/sops/age/keys.txt | \
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin
```

> The filename suffix `.agekey` is required — the controller identifies age keys by this suffix.

---

## Step 5 — Configure Flux to use the global key (Flux 2.7+)

With Flux 2.7+, the age key is configured once on the `kustomize-controller`. No `decryption:` block is needed on individual Kustomizations.

Create a patch file `infrastructure/flux/kustomize-controller-sops-patch.yaml`:

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

Apply via Flux or directly:
```bash
kubectl apply -f infrastructure/flux/kustomize-controller-sops-patch.yaml
```

From this point on, Flux automatically decrypts any `*.sops.yaml` file it encounters in any Kustomization path.

---

## Step 6 — Creating an encrypted secret

The workflow for every service:

```bash
# 1. Generate the plaintext manifest (dry-run, never applied directly)
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=FTLCONF_webserver_api_password="<your-password>" \
  --dry-run=client -o yaml > apps/pihole/pihole-secret.sops.yaml

# 2. Encrypt in place — reads public key from .sops.yaml automatically, no private key needed
sops --encrypt --in-place apps/pihole/pihole-secret.sops.yaml

# 3. Verify it decrypts correctly
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --decrypt apps/pihole/pihole-secret.sops.yaml

# 4. Commit — the encrypted file is safe to push to the public repo
git add apps/pihole/pihole-secret.sops.yaml
git commit -m "feat(pihole): add SOPS-encrypted admin secret"
```

---

## Editing an existing secret

```bash
# SOPS decrypts to a temp file, opens $EDITOR, re-encrypts on save
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops apps/pihole/pihole-secret.sops.yaml
```

---

## Adding a YubiKey as a second recipient (optional, after YubiKey procurement)

Once YubiKeys are available, the YubiKey can be added as a second recipient for local editing. The cluster always uses the software key.

```bash
# Get the YubiKey age public key
age-plugin-yubikey --list

# Add to .sops.yaml (comma-separated)
# age: >-
#   age1software...,
#   age1yubikey...

# Update all existing encrypted files to add the new recipient
for f in $(find apps/ -name "*.sops.yaml"); do
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys "$f"
done

git add -A && git commit -m "feat(sops): add YubiKey as second recipient"
```

This is a non-breaking change — the cluster software key continues to work unchanged.

---

## Recovery after cluster reinstall

**Order is critical:** The age key must be imported before Flux reconciles any encrypted secrets.

```bash
# 1. flux bootstrap (sets up Flux, no encrypted secrets deployed yet)
flux bootstrap github ...

# 2. Import age key from Vaultwarden
cat age.agekey | \
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin

# 3. Apply kustomize-controller patch
kubectl apply -f infrastructure/flux/kustomize-controller-sops-patch.yaml

# 4. Trigger Flux reconciliation — all secrets are now decryptable
flux reconcile kustomization flux-system --with-source
```

---

## Next: [Deploy Pi-hole](../services/pihole.md)
