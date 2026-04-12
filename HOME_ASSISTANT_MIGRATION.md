# Home Assistant — RPi5 Docker to Kubernetes Migration

This guide covers migrating your existing Home Assistant instance from Docker on a
Raspberry Pi 5 to the `home-automation` namespace in Kubernetes.

---

## What moves

Everything lives in a single directory on the RPi5 — the bind mount for the HA
container (typically `/opt/homeassistant` or `/home/<user>/homeassistant`). It
contains:

```
config/
├── configuration.yaml       ← main config
├── automations.yaml         ← automations
├── scripts.yaml             ← scripts
├── scenes.yaml              ← scenes
├── secrets.yaml             ← credentials referenced in config
├── blueprints/              ← automation blueprints
├── custom_components/       ← HACS integrations
├── home-assistant_v2.db    ← SQLite database (history, states, events)
├── home-assistant.log
└── .storage/               ← UI-configured entities, dashboards, users
```

All of this goes into the Longhorn PVC mounted at `/config` in the Kubernetes pod.

---

## Before you start

1. **Note your RPi5 config path** — the host directory mounted into the HA container:
   ```bash
   docker inspect homeassistant | grep -A5 Mounts
   # Look for the "Source" path, e.g. /opt/homeassistant/config
   ```

2. **Stop the HA container** on the RPi5 — do not run two instances simultaneously.
   SQLite will corrupt if two processes write to it at the same time:
   ```bash
   docker stop homeassistant
   ```

3. **Deploy HA in Kubernetes first** — let it start once so the Longhorn PVC is
   provisioned. Then scale it down before copying data:
   ```bash
   kubectl scale deployment -n home-automation home-assistant --replicas=0
   kubectl get pods -n home-automation -w   # wait for pod to terminate
   ```

---

## Copy config from RPi5 to the Longhorn PVC

### Step 1 — Start a temporary copy pod

```bash
kubectl run -n home-automation migrate-ha \
  --image=busybox \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "migrate",
        "image": "busybox",
        "command": ["sleep", "3600"],
        "volumeMounts": [{"mountPath": "/config", "name": "config"}]
      }],
      "volumes": [{
        "name": "config",
        "persistentVolumeClaim": {"claimName": "home-assistant-config"}
      }]
    }
  }'
```

> Verify the PVC name: `kubectl get pvc -n home-automation`

### Step 2 — Copy config from the RPi5

From your workstation (or directly from the RPi5 if it can reach the cluster):

```bash
# Run this on your workstation — ssh into RPi5 and pipe tar through kubectl
ssh pi@<rpi5-ip> "tar -C /opt/homeassistant/config -cf - ." \
  | kubectl exec -n home-automation migrate-ha -i -- tar -C /config -xf -
```

If you can't pipe directly, copy from the RPi5 to your workstation first:

```bash
# On RPi5 — create an archive
tar -C /opt/homeassistant/config -czf /tmp/ha-config.tar.gz .

# On your workstation — copy archive then push into pod
scp pi@<rpi5-ip>:/tmp/ha-config.tar.gz /tmp/ha-config.tar.gz
cat /tmp/ha-config.tar.gz \
  | kubectl exec -n home-automation migrate-ha -i -- \
    tar -C /config -xzf -
```

### Step 3 — Verify the copy

```bash
kubectl exec -n home-automation migrate-ha -- ls /config
# Should show: configuration.yaml, automations.yaml, .storage/, etc.
```

### Step 4 — Clean up the copy pod and start HA

```bash
kubectl delete pod -n home-automation migrate-ha
kubectl scale deployment -n home-automation home-assistant --replicas=1
kubectl logs -n home-automation -l app.kubernetes.io/name=home-assistant -f
```

Wait for the line:
```
Home Assistant initialized in X.Xs
```

---

## Post-migration configuration

### Update the `http:` section

On the RPi5, HA was accessed directly. In Kubernetes it sits behind an Envoy
Gateway reverse proxy. Add this to `configuration.yaml` so HA trusts the proxy
and generates correct URLs:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16    # pod CIDR — replace with your cluster_pod_cidr if different
    - 10.43.0.0/16    # service CIDR — replace with your cluster_svc_cidr if different
```

Without this, HA will log `Request from 10.x.x.x not allowed` and may reject
webhook callbacks or show the wrong external URL.

After editing, restart HA to apply:

```bash
kubectl rollout restart deployment -n home-automation home-assistant
```

### Verify the external URL

In the HA UI go to **Settings → System → Network** and confirm the external URL
is set to `https://home-assistant.<your-domain>`. HA sometimes auto-detects this
from the `X-Forwarded-Host` header, but it is worth confirming.

### Check integrations

- **Cloud-polling integrations** (Hue, Tuya cloud, etc.) — work immediately, no
  change needed
- **Local IP integrations** (Hue bridge, ESPHome, Shelly) — update the device
  IPs if they changed, but integration config itself is preserved from the
  migrated `.storage/` directory
- **Webhooks** — update any external services (e.g. phone app, IFTTT) to point
  to `https://home-assistant.<your-domain>/api/webhook/<id>`
- **Companion app** — update the server URL in the app settings to
  `https://home-assistant.<your-domain>`

---

## Rollback

If something is wrong, the RPi5 is still intact (you only stopped the container,
not deleted it). Start it back up on the RPi5:

```bash
docker start homeassistant
```

The Longhorn PVC can be wiped and the process restarted:

```bash
kubectl scale deployment -n home-automation home-assistant --replicas=0
kubectl delete pvc -n home-automation home-assistant-config
# Flux recreates the PVC on next reconcile
```
