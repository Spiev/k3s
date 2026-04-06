# 05 — Set up Sealed Secrets

Prerequisite: [03 — MetalLB](./03-metallb.md) completed, cluster is running.

Sealed Secrets solves two problems at once:
- **Public repo**: encrypted secrets can be safely committed — only the cluster can decrypt them
- **Disaster recovery**: `kubectl apply -f apps/<service>/` deploys all secrets automatically, no manual restoration needed

---

## Step 1 — Install the controller in the cluster

```bash
# Check current version: https://github.com/bitnami-labs/sealed-secrets/releases
SEALED_SECRETS_VERSION="v0.27.1"

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml
```

> **GitOps note:** Loading the manifest directly from the internet is pragmatic for this manual setup step. Once Flux CD is configured, `controller.yaml` belongs in the repo (`infrastructure/sealed-secrets/controller.yaml`) — Flux then deploys it deterministically from the repo, no internet access required at deploy time, and Renovate can propose updates as PRs.

Check controller status:
```bash
kubectl get pods -n kube-system -l name=sealed-secrets-controller -w
# Wait until 1/1 Running
```

---

## Step 2 — Install the kubeseal CLI on your laptop

kubeseal runs on the **laptop** (not on the Pi) — where you create secrets and commit them to the repo.

```bash
# Arch Linux (x86_64)
SEALED_SECRETS_VERSION="v0.27.1"
KUBESEAL_VERSION="${SEALED_SECRETS_VERSION#v}"   # without leading "v"

curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar xz kubeseal

sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal

# Verify
kubeseal --version
```

> Alternatively via AUR: `paru -S kubeseal` or `yay -S kubeseal`

---

## Step 3 — Back up the key IMMEDIATELY

The controller generates an asymmetric key pair on first start. **This key pair is the only way to decrypt existing SealedSecrets.** If it is lost, all Sealed Secrets in the repo become worthless.

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.yaml
```

**Store in your password manager. Do not commit to the repo.**

Verify the file has content:
```bash
grep "tls.crt" sealed-secrets-key.yaml
# → should show a long base64 line
```

Then delete the local file:
```bash
rm sealed-secrets-key.yaml
```

---

## Step 4 — Create your first SealedSecret (example: Pi-hole)

The workflow is always the same: generate a plain Secret to stdout → pipe through kubeseal → write the SealedSecret to the repo.

```bash
# 1. Generate SealedSecret (replace <your-password>)
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=FTLCONF_webserver_api_password="<your-password>" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/pihole/pihole-sealed-secret.yaml

# 2. Verify: the file contains encrypted data, no plaintext
cat apps/pihole/pihole-sealed-secret.yaml
# → spec.encryptedData.WEBPASSWORD is a long base64 string — no password visible

# 3. Deploy to the cluster
kubectl apply -f apps/pihole/pihole-sealed-secret.yaml

# 4. Verify the real secret was created
kubectl get secret pihole-secret -n pihole
```

The `pihole-sealed-secret.yaml` can safely be committed to the repo:
```bash
git add apps/pihole/pihole-sealed-secret.yaml
git commit -m "feat(pihole): add sealed secret for admin password"
```

> **Namespace binding:** SealedSecrets are bound to namespace + name by default. A SealedSecret for `namespace: pihole` cannot be decrypted in another namespace — this is intentional.

---

## Step 5 — Update .gitignore

The old plain secret files can now be removed from `.gitignore` — or kept as a safety net. The `*-sealed-secret.yaml` files, however, **belong in the repo**:

```bash
# apps/pihole/.gitignore — pihole-secret.yaml stays gitignored (local working file)
# pihole-sealed-secret.yaml is NOT gitignored → commit it
```

---

## Recovery after cluster reinstall

**Order is critical:** The old key must be imported before any services with SealedSecrets are deployed. Otherwise the controller generates a new key and all existing SealedSecrets can no longer be decrypted.

### 1. Install the controller

```bash
SEALED_SECRETS_VERSION="v0.27.1"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml
```

### 2. Import the old key (BEFORE the first service deployment!)

Retrieve the key from the password manager and save it to a temporary file:

```bash
# Import the key
kubectl apply -f sealed-secrets-key.yaml

# Restart the controller so it loads the imported key
kubectl rollout restart deployment sealed-secrets-controller -n kube-system
kubectl rollout status deployment sealed-secrets-controller -n kube-system
# Wait until "successfully rolled out"

# Delete the temporary file
rm sealed-secrets-key.yaml
```

### 3. Verify

```bash
# Verify: controller is using the imported key (not a new one)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key
# → creation date of the key should be from the past (not "just now")
```

### 4. Deploy services

Only now run `kubectl apply -f apps/<service>/` — the SealedSecrets will be decrypted automatically.

---

## Next: [Deploy Pi-hole](../services/pihole.md)
