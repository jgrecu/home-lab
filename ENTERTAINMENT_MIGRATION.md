# Entertainment Stack — Docker to Kubernetes Migration

This guide covers migrating your existing Docker-based *arr stack config into the Kubernetes setup. Videos stay on the NAS (nothing moves). Only app config data needs copying.

---

## What moves and what doesn't

| Data | Location | Action |
|---|---|---|
| App config (Radarr, Sonarr, etc.) | Docker volume / bind mount | Copy into new Longhorn PVC |
| Finished media (movies, TV) | NAS / NFS | Nothing — already mounted via `nfs-media` |
| Active downloads in progress | Docker host disk | Abandon or let finish before migrating |

---

## Before you start

1. **Stop your Docker containers** — do not run both stacks at once. SQLite databases will corrupt if two processes write simultaneously.
2. **Note your Docker data paths** — typically `/opt/appdata/<app>` or `/home/<user>/<app>/config`. Run `docker inspect <container> | grep Mounts` if unsure.
3. **Deploy the Kubernetes apps first** — let each app start once so it creates its initial config structure and the Longhorn PVC is provisioned.
4. **Scale the app to 0 replicas** before copying, so it is not writing while you restore.

---

## The copy procedure

The pattern is: tar the source on the Docker host, pipe it into the running pod's PVC via `kubectl exec`.

### Step 1 — scale down the target app

```bash
kubectl scale deployment -n entertainment <app> --replicas=0
```

Wait for the pod to terminate:

```bash
kubectl get pods -n entertainment -w
```

### Step 2 — spin up a temporary copy pod

The deployment is scaled to 0, so the Longhorn PVC is unbound and available. Start a scratch pod that mounts it:

```bash
kubectl run -n entertainment migrate-<app> \
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
        "persistentVolumeClaim": {"claimName": "<app>-config"}
      }]
    }
  }'
```

> The PVC name is `<app>-config` — check with `kubectl get pvc -n entertainment`.

### Step 3 — copy data from Docker host

From your Docker host, pipe a tar archive directly into the pod:

```bash
tar -C /path/to/docker/config/<app> -cf - . \
  | kubectl exec -n entertainment migrate-<app> -i -- tar -C /config -xf -
```

Replace `/path/to/docker/config/<app>` with your actual bind mount path.

### Step 4 — fix ownership (LinuxServer images)

LinuxServer images (Jackett, Transmission) expect files owned by UID/GID 1000. If your Docker data was owned by root:

```bash
kubectl exec -n entertainment migrate-<app> -- chown -R 1000:1000 /config
```

### Step 5 — clean up the scratch pod and scale back up

```bash
kubectl delete pod -n entertainment migrate-<app>
kubectl scale deployment -n entertainment <app> --replicas=1
```

---

## App-specific notes

### Radarr and Sonarr — database path remapping

Radarr and Sonarr store the path to each file inside their SQLite database (`MediaItems.db` / `Radarr.db`). Your Docker setup likely had movies at `/movies` or `/data/movies`. Kubernetes mounts the media library at `/media`.

After copying config but **before scaling back up**, update the root folder path in the database:

```bash
# Get a shell inside the migrate pod (while it's still running)
kubectl exec -n entertainment migrate-radarr -it -- sh

# Update the path in the SQLite database
sqlite3 /config/radarr.db \
  "UPDATE RootFolders SET Path = '/media/movies' WHERE Path = '/movies';"

# Verify
sqlite3 /config/radarr.db "SELECT * FROM RootFolders;"
exit
```

Same for Sonarr (database is `sonarr.db`, table is `RootFolders`, new path is `/media/tv`).

If sqlite3 is not available in busybox, use the Alpine image instead:

```bash
kubectl run -n entertainment migrate-radarr \
  --image=alpine \
  --restart=Never \
  -- sleep 3600
kubectl exec -n entertainment migrate-radarr -- apk add sqlite
```

### Transmission — settings.json

Transmission writes its config to `settings.json`. The download directory will be set to whatever you used in Docker (e.g. `/downloads`). Kubernetes mounts the shared PVC at `/downloads`, so the path is the same — no changes needed if you used `/downloads` in Docker.

If you used a different path, edit `settings.json` before scaling back up:

```json
{
  "download-dir": "/downloads",
  "incomplete-dir": "/downloads/incomplete"
}
```

### Jackett — no path remapping needed

Jackett config (`ServerConfig.json`, `Indexers/`) is portable. Copy as-is.

### Autobrr — no path remapping needed

Autobrr stores its config and SQLite database under `/config`. Copy as-is. IRC and torrent client connections will need to be re-verified in the UI since hostnames change (Docker bridge IPs → Kubernetes service names).

Update any client URLs in Autobrr's settings from Docker container names to Kubernetes service names:

| Docker | Kubernetes |
|---|---|
| `transmission` or `172.x.x.x` | `transmission.entertainment.svc.cluster.local` |
| `radarr` | `radarr.entertainment.svc.cluster.local` |
| `sonarr` | `sonarr.entertainment.svc.cluster.local` |

### Jellyfin — library rescan required

Copy config (which includes your metadata cache, plugins, and user accounts) as above. On first start, Jellyfin will see the `/media` mount and your existing library — trigger a full library scan from the dashboard to rebuild its internal index.

Transcoding temp files do not need to be copied.

### Jellyseerr — config at `/app/config`

Jellyseerr stores everything (SQLite DB, settings) under `/app/config`. Copy as-is. After starting, re-link Jellyseerr to Jellyfin and the *arr apps using their Kubernetes service names (same table as above).

### Recyclarr — skip the migration

Recyclarr has no meaningful state to migrate. Its job is to push quality profiles to Radarr/Sonarr on each run — it will simply re-sync on the next CronJob trigger. The `/config` PVC only stores a cache that gets rebuilt automatically.

---

## Migration order

Do apps in this order to minimise downtime and dependency issues:

1. **Jackett** — independent, no deps
2. **FlareSolverr** — stateless, no migration needed (just deploy)
3. **Transmission** — needed by Radarr/Sonarr for download client config
4. **Radarr** — depends on Transmission + Jackett being up
5. **Sonarr** — same as Radarr
6. **Autobrr** — update client URLs after Transmission/Radarr/Sonarr are up
7. **Jellyfin** — migrate config, trigger library scan
8. **Jellyseerr** — last, since it connects to Jellyfin + Radarr + Sonarr

---

## Verifying the migration

For each *arr app, check:

- [ ] App starts and the UI is accessible
- [ ] Settings → General → API key is preserved (same key as Docker)
- [ ] Root folder path is correct (`/media/movies` or `/media/tv`)
- [ ] Download client is configured and connected (Transmission at `transmission.entertainment.svc.cluster.local:9091`)
- [ ] Indexers are configured and tested (Jackett at `jackett.entertainment.svc.cluster.local:9117`)
- [ ] Existing library items show as monitored with correct file paths

For Jellyfin:
- [ ] User accounts are present
- [ ] Libraries show up and are scanning
- [ ] Playback works from a client

---

## Rollback

If something goes wrong, your Docker stack is still intact on the Docker host (you only scaled Docker down, not deleted it). Scale Docker containers back up to resume where you left off. The Longhorn PVCs can be wiped and the process restarted:

```bash
# Wipe a PVC and start fresh (Kubernetes side only — NAS data is never touched)
kubectl scale deployment -n entertainment <app> --replicas=0
kubectl delete pvc -n entertainment <app>-config
# Flux will recreate the PVC on next reconcile
```
