# Post-Bootstrap Runbook

Pick up here after completing README.md Stage 6 (`task bootstrap:apps`). At this
point Flux is running and reconciling the cluster. This guide covers everything
that requires a running cluster before it can be configured — the two-step
bootstraps and manual steps that cannot be committed to Git upfront.

---

## Overview

| Step | What | Blocking for |
|---|---|---|
| 1 | Verify Flux is healthy | Everything |
| 2 | Bootstrap Garage S3 | Longhorn backups, CNPG WAL archiving |
| 3 | Bootstrap Forgejo runner | CI/CD pipelines |
| 4 | Deploy entertainment stack | Jellyfin, Radarr, Sonarr, etc. |

Steps 2 and 3 are independent of each other and can be done in parallel.
Step 4 is self-contained — node labeling and Recyclarr bootstrap are both part of it.

---

## Step 1 — Verify Flux is healthy

Before doing anything else, confirm Flux has reconciled cleanly:

```bash
flux get ks -A
```

All Kustomizations should show `True` in the Ready column. Common ones to check:

```bash
flux get hr -A
```

All HelmReleases should be `True / True`. If anything is stuck, investigate before
proceeding:

```bash
flux logs --level=error
kubectl describe ks -n flux-system <name>
```

---

## Step 2 — Bootstrap Garage S3

Garage is the S3-compatible object store used by Longhorn (volume snapshot backups)
and CloudNativePG (continuous WAL archiving). It deploys automatically via Flux but
requires a one-time CLI bootstrap to initialise the cluster layout, create buckets,
and generate access keys.

**Why this is manual:** Garage's node layout (which node owns which data) must be
committed explicitly — Garage will not start serving objects until the layout is
applied. The access keys are randomly generated inside Garage and cannot be
pre-committed to Git.

### 2a — Wait for the Garage pod

```bash
kubectl get pods -n storage -l app.kubernetes.io/name=garage -w
```

Wait until `garage-0` is `Running`.

### 2b — Initialise the cluster layout

```bash
kubectl exec -it -n storage garage-0 -- /bin/sh
```

Inside the shell:

```sh
# Get the node ID
garage status

# Assign the node to a zone and set its capacity.
# Copy the NODE_ID from the output above (the long hex string).
garage layout assign -z dc1 -c 100G <NODE_ID>

# Apply the layout. --version 1 for a fresh cluster.
garage layout apply --version 1

# Verify the layout was accepted
garage status
```

### 2c — Create buckets

```sh
garage bucket create longhorn-backups
garage bucket create cnpg-backups

# Verify
garage bucket list
```

### 2d — Create an access key and grant permissions

```sh
garage key create home-lab
garage key info home-lab
```

Copy the **Key ID** and **Secret key** from the output — you need these in the next step.

```sh
garage bucket allow --read --write --owner longhorn-backups --key home-lab
garage bucket allow --read --write --owner cnpg-backups --key home-lab

# Exit the pod shell
exit
```

### 2e — Store the credentials and re-render

Back on your workstation, fill in `cluster.yaml`:

```yaml
garage_s3_access_key_id: "<Key ID from above>"
garage_s3_secret_access_key: "<Secret key from above>"
```

Re-render, re-encrypt, and commit:

```bash
task template:render
sops --encrypt --in-place kubernetes/apps/storage/garage/app/secret.sops.yaml
git add kubernetes/apps/storage/
git commit -m "feat: add garage S3 credentials"
git push
```

Flux reconciles and updates the Longhorn backup secret and all CNPG cluster backup
secrets automatically. Longhorn will now ship volume snapshots to
`s3://longhorn-backups` and every CNPG database will stream WAL segments to
`s3://cnpg-backups/<db-name>/`.

### 2f — Verify backups are working

```bash
# Longhorn backup target should show Connected
kubectl get -n storage setting backup-target -o jsonpath='{.value}'
```

```bash
# CNPG continuous archiving should be True
kubectl get cluster -n forgejo forgejo-postgres -o jsonpath='{.status.conditions}' | jq .
```

---

## Step 3 — Bootstrap Forgejo runner

The Forgejo Actions runner needs a registration token generated inside the Forgejo
UI. Forgejo itself deploys automatically via Flux; the runner pod starts but fails
to register until the token is provided.

### 3a — Wait for Forgejo to be healthy

```bash
kubectl get pods -n forgejo -w
```

Wait until all Forgejo pods are `Running`. Then open the Forgejo web UI:

```
https://forgejo.<your-domain>
```

### 3b — Generate a runner token

1. Log in with your admin account (`forgejo_admin_email` / `forgejo_admin_password` from `cluster.yaml`)
2. Go to **Site Administration** (top-right menu → Site Administration)
3. Go to **Runners** → **Create new runner token**
4. Copy the token

### 3c — Store the token and re-render

Fill in `cluster.yaml`:

```yaml
forgejo_runner_secret: "<token from above>"
```

Re-render, re-encrypt, and commit:

```bash
task template:render
sops --encrypt --in-place kubernetes/apps/forgejo/app/secret.sops.yaml
git add kubernetes/apps/forgejo/
git commit -m "feat: add forgejo runner token"
git push
```

Flux reconciles. The runner pod restarts and registers with Forgejo.

### 3d — Verify the runner is registered

In the Forgejo UI: **Site Administration → Runners** — the runner should appear
with status `Active`. Or from the CLI:

```bash
kubectl logs -n forgejo -l app.kubernetes.io/name=forgejo-runner --tail=20
# Should show: "runner registered successfully"
```

---

## Step 4 — Deploy entertainment stack

### 4a — NAS share structure

The `nfs-media` StorageClass mounts your NAS share root directly. Create these
directories on your NAS before deploying:

```
/videos/          ← whatever your nfs_media_path is in cluster.yaml
├── movies/       ← Radarr's root folder
└── tv/           ← Sonarr's root folder
```

### 4b — Label the media node

Transmission, Radarr, and Sonarr share a single `ReadWriteOnce` Longhorn PVC
(`media-downloads`). All three must run on the same node. Pick one of your three
nodes and label it:

```bash
kubectl label node <node-name> media-node=true

# Verify
kubectl get nodes --show-labels | grep media-node
```

### 4c — cluster.yaml — initial values

Fill in these fields before the first render. Leave the Recyclarr API keys empty
for now — they come from step 4g after Radarr and Sonarr are running:

```yaml
nfs_media_path: "/videos"        # your NAS media share export path

recyclarr_radarr_api_key: ""     # leave empty — filled in at step 4g
recyclarr_sonarr_api_key: ""     # leave empty — filled in at step 4g
```

### 4d — Render, encrypt, commit

```bash
task template:render
sops --encrypt --in-place kubernetes/apps/entertainment/recyclarr/app/secret.sops.yaml
git add kubernetes/apps/entertainment/
git commit -m "feat: add entertainment namespace"
git push
```

Flux picks up the commit and begins reconciling. The `entertainment` namespace and
all apps are created.

### 4e — Deploy order and what to watch for

```bash
# Watch all entertainment pods come up
kubectl get pods -n entertainment -w
```

Apps come up in the order Flux resolves their dependencies. Expected sequence:

1. **FlareSolverr** — stateless, starts immediately
2. **Jackett** — waits for its Longhorn PVC to provision (~30s)
3. **Autobrr** — independent, starts alongside Jackett
4. **Transmission** — waits for `media-downloads` PVC + media-node scheduling
5. **Radarr / Sonarr** — wait for their own PVCs + media-node scheduling
6. **Jellyfin** — waits for its 10Gi config PVC + nfs-media PVC
7. **Jellyseerr** — starts independently
8. **Recyclarr** — CronJob, first run in up to 6 hours (or trigger manually at step 4g)

If a pod is stuck in `Pending`, check:

```bash
kubectl describe pod -n entertainment <pod-name>
# Common causes: PVC not provisioned yet, no node with media-node=true label
```

### 4f — Post-deploy UI configuration

#### Jackett

```bash
kubectl port-forward -n entertainment svc/jackett 9117:9117
```

- Add your torrent indexers
- Copy the **Jackett API key** from the top of the UI — you'll need it for Radarr/Sonarr

#### Radarr

```bash
kubectl port-forward -n entertainment svc/radarr 7878:7878
```

1. **Settings → Media Management → Root Folders** → Add `/media/movies`
2. **Settings → Download Clients** → Add Transmission:
   - Host: `transmission.entertainment.svc.cluster.local`
   - Port: `9091`
3. **Settings → Indexers** → Add Jackett:
   - URL: `http://jackett.entertainment.svc.cluster.local:9117`
   - API Key: (from Jackett UI)
4. **Settings → General → API Key** → copy this — needed for Recyclarr at step 4g
5. **Settings → Media Management → File Management → Import Mode** → set to `Copy`
   (downloads and media are on different filesystems — hardlinks won't work)

#### Sonarr

```bash
kubectl port-forward -n entertainment svc/sonarr 8989:8989
```

Same steps as Radarr, substituting root folder `/media/tv` and port `8989`.
Copy the Sonarr API key from Settings → General.

#### Transmission

```bash
kubectl port-forward -n entertainment svc/transmission 9091:9091
```

Works out of the box. Optionally:
- **Preferences → Speed** — set global speed limits
- **Peer port** (51413) — forward this on your router for better connectivity

#### Autobrr

```bash
kubectl port-forward -n entertainment svc/autobrr 7474:7474
```

Configure IRC networks and filters. Add download clients using Kubernetes service names:

| Client | Host | Port |
|---|---|---|
| Transmission | `transmission.entertainment.svc.cluster.local` | `9091` |
| Radarr | `radarr.entertainment.svc.cluster.local` | `7878` |
| Sonarr | `sonarr.entertainment.svc.cluster.local` | `8989` |

#### Jellyfin

Access at `https://jellyfin.<your-domain>` (external gateway). On first boot:

1. Create your admin account
2. Add libraries: **Movies** → `/media/movies`, **TV Shows** → `/media/tv`
3. Let the initial library scan complete

#### Jellyseerr

Access at `https://jellyseerr.<your-domain>` (external gateway). On first boot:

1. Sign in with your Jellyfin account
2. Connect to Jellyfin: `http://jellyfin.entertainment.svc.cluster.local:8096`
3. Connect to Radarr: `http://radarr.entertainment.svc.cluster.local:7878`, API key from above
4. Connect to Sonarr: `http://sonarr.entertainment.svc.cluster.local:8989`, API key from above

### 4g — Bootstrap Recyclarr

Recyclarr's config is a SOPS-encrypted secret rendered from `cluster.yaml`. The
API keys it needs only exist after Radarr and Sonarr are configured above.

Fill in `cluster.yaml`:

```yaml
recyclarr_radarr_api_key: "<paste Radarr API key>"
recyclarr_sonarr_api_key: "<paste Sonarr API key>"
```

Re-render, re-encrypt, and commit:

```bash
task template:render
sops --encrypt --in-place kubernetes/apps/entertainment/recyclarr/app/secret.sops.yaml
git add kubernetes/apps/entertainment/recyclarr/
git commit -m "feat: add recyclarr API keys"
git push
```

Trigger a manual sync to verify immediately rather than waiting up to 6 hours:

```bash
kubectl create job -n entertainment --from=cronjob/recyclarr recyclarr-manual
kubectl logs -n entertainment -l job-name=recyclarr-manual -f
```

A successful run ends with:
```
[INF] Processing Radarr with name [movies]
[INF] Processing Sonarr with name [shows]
[INF] Recyclarr completed successfully
```

To customise quality profiles and custom formats, edit
`templates/config/kubernetes/apps/entertainment/recyclarr/app/secret.sops.yaml.j2`
and re-render. The [TRaSH Guides](https://trash-guides.info) document every option.

### 4h — Verify the full pipeline

```bash
kubectl get pods -n entertainment      # all Running
kubectl get pvc -n entertainment       # all Bound
kubectl get jobs -n entertainment      # recyclarr-manual Completed
```

Drop a test torrent in Transmission, confirm Radarr/Sonarr import it to
`/media/movies` or `/media/tv`, and verify it appears in Jellyfin after the next
library scan.

---

## Cluster is production-ready

At this point:

- Flux is reconciling all namespaces
- Garage is storing Longhorn snapshots and CNPG WAL segments
- CNPG databases have point-in-time recovery enabled
- Forgejo is running with active CI/CD runners
- The media stack is live with quality profiles synced by Recyclarr
- Tuppr will handle Talos and Kubernetes upgrades automatically on Sunday 02:00 UTC
- Renovate will open PRs for version bumps on the weekend schedule

For ongoing operations, the only manual steps are:
- Merging Renovate PRs (Tuppr handles the actual node upgrades after merge)
- Adjusting `recyclarr.yml` as your quality preferences evolve
