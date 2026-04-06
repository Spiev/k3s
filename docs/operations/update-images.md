# Image Updates

Guide for manually updating container images.

---

## Manual Image Update

Update the tag in the manifest and apply:

```bash
kubectl apply -f apps/<service>/<service>.yaml
```

Kubernetes detects the change and triggers a rolling update automatically.

Monitor progress:

```bash
kubectl rollout status deployment/<name> -n <namespace>
```

---

## Special Case: Services with RWO PVC (e.g. Pi-hole)

Services using a RWO (ReadWriteOnce) PVC use `strategy: Recreate` — the old pod is terminated
before the new one starts. During image pull, DNS (or another critical service) will be briefly
unavailable.

**Solution: pre-pull the image manually** (`crictl` is included with k3s):

```bash
sudo crictl pull <image>:<tag>
```

The image is then cached locally and Recreate downtime is reduced to a few seconds
(no pull delay).

### Example: Pi-hole

```bash
sudo crictl pull pihole/pihole:2026.04.0
kubectl apply -f apps/pihole/pihole.yaml
kubectl rollout status deployment/pihole -n pihole
```

> **Note:** This issue goes away once Pi-hole runs as an HA setup with two instances behind
> MetalLB (one per node). Rolling updates without downtime are then possible.
