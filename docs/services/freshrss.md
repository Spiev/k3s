# Deploy & Migrate FreshRSS

Prerequisite: [02 — Install k3s](../platform/02-k3s-install.md) completed, cluster is running.

FreshRSS is the first service migrated from Docker to k3s. It has a single volume (`/config`) and no external database — ideal as a starting point.

---

## Manifest overview

```
apps/freshrss/
├── freshrss.yaml                  ← in repo (Namespace, PVC, Deployment, Service)
├── freshrss-ingress.yaml          ← .gitignore (real domain)
└── freshrss-ingress.yaml.example  ← in repo (template)
```

The real domain is only in `freshrss-ingress.yaml`, which is excluded from the repo via `.gitignore`.

---

## 1. Enter your domain

```bash
cp apps/freshrss/freshrss-ingress.yaml.example apps/freshrss/freshrss-ingress.yaml
# Edit freshrss-ingress.yaml and enter your real domain
```

---

## 2. Apply manifests

```bash
kubectl apply -f apps/freshrss/
```

Monitor status:
```bash
kubectl get all -n freshrss
# Pod should be Running and Ready 1/1 after ~30 seconds

kubectl get pvc -n freshrss
# STATUS = Bound → local-path has provisioned the volume

kubectl get ingress -n freshrss
# Shows the configured domain and the node IP
```

---

## 3. Quick smoke test (before migration)

Before migrating the data, verify that FreshRSS starts at all:

```bash
# Port-forward directly to the pod
kubectl port-forward -n freshrss deploy/freshrss 8080:80
```

Browser: `http://localhost:8080` → the FreshRSS setup page should appear.

If that works: stop the port-forward (`Ctrl+C`), proceed to data migration.

---

## 4. Preparation: OPML export

Before starting the migration, export the feed list as OPML and commit it to the repo. This is a safety net in case something goes wrong during the transfer — feed subscriptions are backed up independently of the database.

In the FreshRSS UI on the old Raspi:
```
Settings → Import/Export → Export OPML
```

Place the downloaded file in the repo:
```bash
cp ~/Downloads/freshrss-export.opml apps/freshrss/feeds.opml
git add apps/freshrss/feeds.opml
git commit -m "chore(freshrss): add opml feed export pre-migration"
```

Keep the OPML file up to date after any significant changes to subscriptions — it serves as a readable backup of the feed list, independent of the PVC.

**In an emergency** (volume lost, starting from scratch): set up FreshRSS fresh, import OPML → all feeds are immediately back. Read state and cached articles would be gone, the feeds themselves would not.

---

## 6. Data migration

### Strategy

```
Stop Docker FreshRSS
  → copy config directory to the new Raspi
    → import into the local-path PVC
      → redirect nginx to the new Raspi
        → remove Docker container
```

Docker and k3s run on different machines — data transfer goes over SSH.

### Step 1 — Stop Docker FreshRSS

On the old Raspi:
```bash
cd ~/docker/freshrss    # or wherever your docker-compose.yml is
docker compose stop freshrss
```

The container is stopped, data in `./config/` is consistent.

### Step 2 — Start a helper pod that mounts the PVC

On the new Raspi (k3s):

> **fish note:** `<<EOF` is bash syntax. Switch to bash briefly:

```bash
bash   # switch to bash temporarily

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

exit   # back to fish

kubectl wait --for=condition=Ready pod/migration -n freshrss --timeout=30s
```

### Step 3 — Transfer data

From your laptop (or directly from the old Raspi):
```bash
# From the laptop: first fetch from old Raspi, then push into the cluster
# (or directly from the old Raspi if you're logged in there)

# Option A: laptop as intermediary
rsync -av <user>@<old-raspi>:~/docker/freshrss/config/ /tmp/freshrss-config/
kubectl cp /tmp/freshrss-config/. freshrss/migration:/config/

# Option B: directly from old Raspi into the cluster (requires kubectl access on old Raspi)
# rsync -av ./config/ <user>@<raspi5>:/tmp/freshrss-config/
# kubectl cp /tmp/freshrss-config/. freshrss/migration:/config/
```

Verify the data arrived:
```bash
kubectl exec -n freshrss migration -- ls /config
# Should show www/, log/ etc. — the FreshRSS directory structure
```

> **Important:** `kubectl cp` always copies files as `root`. However, linuxserver images run as user `abc` — fix permissions after copying:
>
> ```bash
> kubectl exec -n freshrss deploy/freshrss -- chown -R abc:users /config/www/freshrss/data/users/
> ```
>
> Without this step, FreshRSS cannot write the read state and other user data.

### Step 4 — Remove the helper pod

```bash
kubectl delete pod migration -n freshrss
```

The FreshRSS Deployment restarts automatically and finds the copied data.

### Step 5 — Test (without switching nginx yet)

```bash
kubectl port-forward -n freshrss deploy/freshrss 8080:80
```

`http://localhost:8080` → FreshRSS should appear with your feeds and settings — no setup wizard, logged in directly.

---

## 7. Redirect nginx

On the old Raspi, update the nginx configuration's `proxy_pass` for FreshRSS from `localhost:8080` to the new Raspi:

```nginx
# before:
proxy_pass http://localhost:8080;

# after (IP of the new Raspi 5):
proxy_pass http://<server-ip>;   # port 80, Traefik handles the routing
```

```bash
docker compose restart nginx   # or however you reload nginx
```

FreshRSS is now reachable via your usual domain — but served from k3s.

---

## 8. Remove the Docker container

Once everything is working:
```bash
# On the old Raspi
docker compose rm freshrss
# The config/ directory can stay as a backup for a while
```

---

## 9. Troubleshooting

```bash
# Pod not starting?
kubectl describe pod -n freshrss -l app=freshrss
kubectl logs -n freshrss -l app=freshrss

# Ingress not matching?
kubectl describe ingress -n freshrss freshrss

# Check PVC status
kubectl describe pvc -n freshrss freshrss-config

# FreshRSS shows wrong URLs (http instead of https)?
# nginx must set X-Forwarded-Proto: https — check proxy-headers.conf
```

---

## Next: [Deploy Pi-hole](./pihole.md)
