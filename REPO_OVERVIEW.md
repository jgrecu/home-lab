# Home Lab Repository Overview

## What is this repo?

This is a **home-lab Kubernetes cluster** — essentially a recipe for turning physical machines (or VMs) in your home into a fully production-grade Kubernetes setup. It's based on a popular community template called `onedr0p/cluster-template`.

Think of it like a blueprint for a house. The house doesn't exist yet — you fill in the details (your hardware, your domain, your IP ranges) and the tools build it for you.

---

## The Big Picture — How it all fits together

```
Your machines (bare metal / VMs)
        |
        | [Talos Linux — OS layer]
        |
   Kubernetes cluster
        |
        | [Flux CD — watches this Git repo]
        |
   Applications defined in this repo
        |
        | [Cloudflare — external access]
        |
   The internet
```

Everything flows from Git. If you want to deploy something, you commit it here. Flux picks it up and makes it happen. That pattern is called **GitOps**.

---

## Layer 1: The Operating System — Talos Linux

Most people install Ubuntu or Fedora on their servers. This repo uses **Talos Linux** instead. Talos is different:

- It has **no shell, no SSH** — you control it entirely via an API (`talosctl`)
- It is **read-only and immutable** — you can't accidentally misconfigure it at runtime
- It is **purpose-built for Kubernetes** — nothing else runs on it

The config for each node lives in `talos/talconfig.yaml`. Tools like `talhelper` render it into per-node config files under `talos/clusterconfig/`.

### Automated upgrades — Tuppr

Talos and Kubernetes upgrades are handled automatically by **Tuppr** (Talos Linux Upgrade Controller), a Kubernetes controller from the `home-operations` community that runs in the `system-upgrade` namespace.

Two custom resources drive the process:

- **`TalosUpgrade`** — defines the target Talos version and upgrade policy. Tuppr drains each node, upgrades it, waits for it to return `Ready`, then moves to the next. All three nodes are upgraded one at a time so the cluster stays available throughout.
- **`KubernetesUpgrade`** — defines the target Kubernetes version. Runs after Talos upgrades complete.

Both CRs include **Renovate annotations** on the version field:

```yaml
talos:
  # renovate: datasource=docker depName=ghcr.io/siderolabs/installer
  version: v1.9.5
```

When Renovate opens a PR bumping the installer image, merging it updates the version in the CR. Tuppr picks it up during the next **maintenance window** (Sunday 02:00 UTC, 4 hours) and rolls the upgrade across all three nodes automatically.

Tuppr requires the Talos API to be accessible from inside the cluster. The global Talos patch `machine-tuppr.yaml.j2` enables this by granting the `system-upgrade` namespace `os:admin` access via `kubernetesTalosAPIAccess`. Without this patch applied to every node before bootstrapping, Tuppr cannot issue upgrade or reboot commands.

---

## Layer 2: Kubernetes Networking — Cilium

Every Kubernetes cluster needs a **CNI** (Container Network Interface) — basically the plumbing that lets pods talk to each other. This repo uses **Cilium**, which is the most capable CNI available today.

Cilium does several jobs here:
- Routes traffic between pods
- Replaces `kube-proxy` entirely (faster, eBPF-based)
- Handles **L4 Load Balancing** — when a Service gets an IP, Cilium answers for it on the local network
- Optionally runs **BGP** to advertise LoadBalancer IPs to your router

---

## Layer 3: GitOps — Flux CD

**Flux** is the engine that keeps your cluster in sync with this Git repo. You never `kubectl apply` manually in production — instead:

1. You push a change to Git
2. Flux detects it (every hour, or via webhook)
3. Flux applies it to the cluster

The core Flux config lives in `kubernetes/flux/`. It points at the rest of `kubernetes/apps/` which has every application organised by namespace.

---

## Layer 4: Applications — What actually runs

Under `kubernetes/apps/` you'll find apps grouped by **namespace** (a logical partition in Kubernetes):

| Namespace | What lives there |
|---|---|
| `cert-manager` | Automatically fetches TLS certificates from Let's Encrypt |
| `network` | Ingress (Envoy Gateway), DNS (k8s_gateway), Cloudflare Tunnel, Pi-hole |
| `storage` | Longhorn (replicated block storage), NFS CSI driver, Garage (S3 object store) |
| `database` | CloudNativePG operator — manages all PostgreSQL instances in the cluster |
| `forgejo` | Forgejo git hosting, container registry, Actions CI/CD, runners |
| `immich` | Immich photo/video library (self-hosted Google Photos) |
| `cloud` | Nextcloud — self-hosted file storage and sync |
| `entertainment` | Jellyfin, Jellyseerr, Kavita, Autobrr, Jackett, Transmission, Radarr, Sonarr, Recyclarr, FlareSolverr |
| `observability` | Prometheus, Grafana, Loki, Fluent Bit, smartctl-exporter, Gatus, Kromgo |
| `system-upgrade` | Tuppr — automated Talos Linux and Kubernetes upgrades |
| `flux-system` | Flux itself |
| `kube-system` | CoreDNS, metrics-server, Spegel |
| `default` | Homepage dashboard, echo test app |

### App access overview

**External** (reachable from the internet via Cloudflare Tunnel):

| App | URL |
|---|---|
| Forgejo | `https://forgejo.yourdomain.com` |
| Immich | `https://immich.yourdomain.com` |
| Nextcloud | `https://nextcloud.yourdomain.com` |
| Kavita | `https://kavita.yourdomain.com` |
| Jellyfin | `https://jellyfin.yourdomain.com` |
| Jellyseerr | `https://jellyseerr.yourdomain.com` |

**Internal only** (home network only):

| App | URL |
|---|---|
| Homepage | `https://homepage.yourdomain.com` |
| Pi-hole | `https://pihole.yourdomain.com` |
| Grafana | `https://grafana.yourdomain.com` |
| Gatus | `https://gatus.yourdomain.com` |
| Kromgo | `https://kromgo.yourdomain.com` |
| Autobrr | `https://autobrr.yourdomain.com` |

---

## Layer 5: Persistent Storage — Longhorn & NFS

Kubernetes pods are ephemeral — when a pod restarts, any data written to its filesystem is lost. **Persistent Volumes (PVs)** solve this by mounting storage that outlives the pod.

This repo uses two storage backends:

### Longhorn — replicated block storage (default)

Longhorn runs as a DaemonSet on all 3 nodes and pools their local SSDs together into a distributed storage system.

- Every volume is stored as **2 replicas** spread across different nodes
- If one node dies, your data is safe on the other two
- Longhorn is the **default StorageClass** — any PVC without an explicit class uses it automatically
- Has a web UI for managing volumes, replicas, and backups

**Requires:** The `iscsi-tools` system extension must be added to your Talos schematic at [factory.talos.dev](https://factory.talos.dev) before bootstrapping.

### NFS — network storage from your NAS (opt-in)

If you have a NAS (Synology, TrueNAS, etc.), the NFS CSI driver lets pods mount shares from it directly as Persistent Volumes.

- Not replicated — data lives on the NAS
- Good for large files: media, backups, shared datasets
- Uses StorageClass `nfs` — opt in per PVC with `storageClassName: nfs`
- Each PVC gets its own isolated subdirectory automatically

### NFS Media — dedicated share for the media library (opt-in)

A second NFS StorageClass `nfs-media` points at your media library share on the NAS. It is configured **without** per-PVC subdirectories so Radarr, Sonarr, and Jellyfin all mount the same share root and see a consistent library.

**Downloads stay on Longhorn (local SSD).** Transmission writes to a Longhorn PVC during download. When a download completes, Radarr/Sonarr import it — copying it from the Longhorn PVC to the NFS media share, then deleting the original. The copy happens once at import time and then the local SSD space is freed.

The trade-off vs keeping downloads on NFS:
- No hard-linking (copy+delete instead of instant rename) — fine for a home lab
- Downloads benefit from fast local SSD I/O during the actual download
- NAS only stores your finished, organised media library

**Node pinning:** Longhorn PVCs are `ReadWriteOnce` — only one node can mount them at a time. Since Transmission, Radarr, and Sonarr all need access to the same downloads folder, all three apps should be pinned to the same node via a `nodeSelector`. This is set in each app's HelmRelease when you deploy them.

**Required NAS share structure** (set this up on your NAS before deploying media apps):

```
/volume1/media/
├── movies/     ← Radarr's library
├── tv/         ← Sonarr's library
└── music/      ← optional
```

### The golden rule for storage in this repo

> **Config and state → Longhorn. Large data (photos, media) → NFS.**

Every app follows this split:
- App configuration, databases, job queues, block lists, model caches — all on **Longhorn** (fast local SSD, replicated, survives node failure)
- Photo libraries, media libraries — on **NFS** (NAS has the capacity, is already backed up, accessible from other devices)

### `longhorn-single` — for CNPG databases only

CNPG with `instances: 2` already keeps a streaming standby on a second node — that *is* the replication. If Longhorn also replicated each volume 2×, you'd have 4 copies of the same data. `longhorn-single` gives each CNPG instance exactly 1 Longhorn replica, resulting in 2 total copies across 2 nodes. Correct HA, no waste.

**Never use `longhorn-single` for regular apps** — those rely on Longhorn's 2-replica replication for HA since they have no built-in replication of their own.

### Storage class summary

| Class | Replicas | Where data lives | When to use |
|---|---|---|---|
| `longhorn` | 2 | Local SSD across nodes | App config, downloads, all stateful apps |
| `longhorn-single` | 1 | Local SSD, single node | CNPG databases only |
| `nfs` | 1 (NAS) | Your NAS (per-PVC subdirs) | General large files, backups |
| `nfs-media` | 1 (NAS) | Your NAS (shared root) | Radarr, Sonarr, Jellyfin |
| `nfs-photos` | 1 (NAS) | Your NAS (shared root) | Immich photo/video library |
| `nfs-books` | 1 (NAS) | Your NAS (shared root) | Kavita book/manga/comic library (in `entertainment` namespace) |
| `nfs-nextcloud` | 1 (NAS) | Your NAS (shared root) | Nextcloud user data |
| `nfs-garage` | 1 (NAS) | Your NAS (shared root) | Garage S3 object data |

All app-specific NFS StorageClasses (`nfs-media`, `nfs-photos`, `nfs-books`, `nfs-nextcloud`, `nfs-garage`) share two important properties:
- **No `subDir`** — the PVC mounts the share root directly, so any data already on the NAS is visible immediately. The CSI driver does not create subdirectories or modify existing content.
- **`reclaimPolicy: Retain`** — deleting a PVC in Kubernetes never deletes the underlying NAS data. You are always in control of what gets removed from the NAS.

### Required `cluster.yaml` fields for storage

```yaml
nfs_server_addr: "192.168.1.37"    # IP of your NAS
nfs_server_path: "/k8s"            # NFS export for general app use
nfs_media_path: "/videos"          # NFS export for the media library
nfs_photos_path: "/immich"         # NFS export for Immich photo library
nfs_books_path: "/books"           # NFS export for Kavita book library
nfs_nextcloud_path: "/nextcloud"   # NFS export for Nextcloud user data
nfs_garage_path: "/garage"         # NFS export for Garage S3 object data

garage_rpc_secret: ""              # openssl rand -hex 32
garage_admin_token: ""             # openssl rand -base64 32
garage_s3_access_key_id: ""        # filled in after Garage bootstrap
garage_s3_secret_access_key: ""    # filled in after Garage bootstrap
```

---

## Layer 6: S3 Object Storage — Garage

Garage is a lightweight, S3-compatible object store that runs inside the cluster. It provides the backup target for both Longhorn volume snapshots and CloudNativePG continuous WAL archiving — giving you Point-in-Time Recovery (PITR) for every database in the cluster.

### Why Garage instead of MinIO

| | MinIO | Garage |
|---|---|---|
| RAM per node | ~256Mi+ | ~50Mi |
| Designed for | Large clusters, cloud scale | Small clusters, home labs |
| Licensing | AGPL + commercial enforcement | AGPL, permissive enforcement |
| Complexity | Medium | Low |
| S3-compatible | Yes | Yes |

Garage was purpose-built for exactly this use case: a small number of nodes, commodity hardware, minimal overhead.

### Storage layout

Garage splits its storage across two backends, following the same rule as every other app in this repo:

| What | Where | Why |
|---|---|---|
| Cluster metadata (node layout, bucket config, key index, object index) | Longhorn 2Gi | Small, latency-sensitive, must survive node failure |
| Object data (the actual bytes of every backup) | `nfs-garage` (NAS) | Large capacity, already on NAS which is your primary backup target |

The NFS share is mounted at the share root (no subDir). `reclaimPolicy: Retain` means deleting the PVC never touches NAS data.

### What connects to Garage

```
Longhorn ──────────────────────────────→ s3://longhorn-backups   (volume snapshots)
CNPG forgejo-postgres ─────────────────→ s3://cnpg-backups/forgejo-postgres/
CNPG immich-postgres ──────────────────→ s3://cnpg-backups/immich-postgres/
CNPG nextcloud-postgres ───────────────→ s3://cnpg-backups/nextcloud-postgres/
```

All connections use the internal ClusterIP address: `garage.storage.svc.cluster.local:3900`. Garage is never exposed externally.

### What CNPG backup actually gives you

CNPG uses `barman-cloud` to continuously stream WAL segments to Garage as they are written. Combined with periodic base backups, this means:

- **Any database can be restored to any point in time** within the retention window (30 days)
- If a CNPG cluster is accidentally dropped, you can recover it with a single manifest change pointing at the S3 path
- WAL archiving runs on the primary — the standby continues streaming replication independently, so backups don't add load to reads

### Important: PGDATA stays on Longhorn

PostgreSQL's PGDATA directory (and WAL) must stay on **local block storage** (Longhorn). NFS is explicitly unsupported for PGDATA by CloudNativePG because PostgreSQL's crash recovery depends on `fsync()` guarantees that NFS cannot reliably provide. Putting PGDATA on NFS risks silent data corruption. The NAS is only used for the Garage object store — backup *copies* of data, not live database files.

### Two-step bootstrap (same pattern as Forgejo runner)

Garage S3 access keys only exist after the cluster is initialised. The full command sequence is documented in `storage/garage/ks.yaml`. The short version:

1. Deploy with empty `garage_s3_access_key_id` / `garage_s3_secret_access_key`
2. `kubectl exec -it -n storage garage-0 -- /bin/sh` and run the layout + bucket + key commands
3. Paste the generated key into `cluster.yaml`, re-render, commit
4. Flux reconciles — Longhorn and all CNPG backup secrets update automatically

---

## Layer 7: Databases — CloudNativePG

Rather than bundling a PostgreSQL chart inside every app that needs a database, this repo uses the **CloudNativePG (CNPG) operator**. It is deployed once in the `database` namespace and then manages all PostgreSQL instances across the cluster via a Kubernetes-native `Cluster` CRD.

### Why this is better than per-app PostgreSQL subcharts

| | Subchart per app | CloudNativePG |
|---|---|---|
| Operator instances | One per app | One for the whole cluster |
| Credential management | Password in `cluster.yaml` | Auto-generated, stored in Kubernetes secret |
| Failover | Manual | Automatic |
| Backups | DIY | Built-in (S3/object store) |
| Consistency | Each app configures it differently | Standardised `Cluster` CRD everywhere |
| Storage efficiency | Longhorn 2× replicas | `longhorn-single` 1× replica — CNPG already replicates |

### How it works

When you add `postgres.yaml` to an app's directory, CNPG provisions the database and automatically creates a secret `<cluster-name>-app` in the same namespace containing:

```
username, password, host, port, dbname, uri
```

The app reads credentials directly from that secret — no passwords in `cluster.yaml`, no manual secret management.

### Adding PostgreSQL to any future app

Copy this one file into the app's `app/` directory:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: myapp-postgres
spec:
  instances: 2                        # primary + 1 standby = HA
  storage:
    storageClass: longhorn-single     # 1 Longhorn replica — CNPG replicates itself
    size: 5Gi
  bootstrap:
    initdb:
      database: myapp
      owner: myapp
```

CNPG creates `myapp-postgres-app` secret. The app references `secretKeyRef: name: myapp-postgres-app, key: password`. Done.

### Why `longhorn-single` for databases

CNPG with `instances: 2` keeps a primary and a streaming standby on two different nodes. Each holds one full copy of the data. If Longhorn also replicated each of those volumes 2×, you'd have 4 copies total — wasting SSD space on data you don't need that much redundancy for. `longhorn-single` gives each CNPG instance exactly 1 Longhorn replica, resulting in 2 total copies across 2 nodes. Correct HA, no waste.

### Dependency chain

The CNPG operator must be running before any `Cluster` CR is applied (otherwise Kubernetes doesn't know what a `Cluster` resource is). Apps that use CNPG declare `dependsOn: cloudnative-pg` in their `ks.yaml` to enforce this ordering.

---

## Layer 8: Developer Platform — Forgejo

Forgejo is a self-hosted Git platform (similar to GitHub) that runs entirely inside your cluster. One service covers three needs:

### Git hosting
Push and pull code over HTTPS from anywhere via the external gateway:
```
git remote add origin https://forgejo.yourdomain.com/you/repo.git
```
SSH cloning (`git@forgejo...`) requires a separate TCP load balancer — Cloudflare Tunnel only handles HTTPS. For a home lab, HTTPS remotes are simpler.

### Built-in container registry
Every Forgejo instance includes an OCI-compatible container registry. No separate registry needed:
```
docker push forgejo.yourdomain.com/you/image:tag
docker pull forgejo.yourdomain.com/you/image:tag
```

### Forgejo Actions (CI/CD)
GitHub Actions-compatible pipeline system. Your `.forgejo/workflows/*.yaml` files run on the **forgejo-runner** pods inside the cluster. Two runner replicas means two jobs can run in parallel.

### Two-step runner deploy

The runner registration token (`forgejo_runner_secret`) only exists after Forgejo
is running — it is generated inside the Forgejo UI. This is the same two-commit
pattern used by Garage credentials and Recyclarr API keys: deploy first with an
empty value, get the token, commit again with the real value.

1. **First commit** — set `forgejo_runner_secret: ""` in `cluster.yaml`, render and commit.
   Flux deploys Forgejo itself (`wait: true` on the Forgejo ks.yaml ensures it is
   healthy before the runner Kustomization is applied). The runner pod starts but
   fails to register — expected and harmless.
2. Log in → **Site Administration → Runners → New runner token** → copy token
3. **Second commit** — paste token into `cluster.yaml` as `forgejo_runner_secret`,
   re-render, re-SOPS-encrypt `forgejo/app/secret.sops.yaml`, commit.
4. Flux reconciles — runner registers and starts accepting jobs.

### Required `cluster.yaml` fields

```yaml
forgejo_admin_email: "you@example.com"
forgejo_admin_password: "strongpassword"
forgejo_runner_secret: ""   # fill in after step 3 above
```

Note: there is no `forgejo_db_password` — CNPG generates the database password automatically and stores it in the `forgejo-postgres-app` secret. Forgejo reads it from there at runtime.

---

## Layer 9: Photo Library — Immich

Immich is a self-hosted alternative to Google Photos. It runs entirely inside the cluster and provides automatic mobile backup, face recognition, CLIP semantic search ("photos of the beach"), albums, and sharing.

### Storage split

| What | Where | Why |
|---|---|---|
| Originals, thumbnails, encoded videos | `nfs-photos` (NAS) | Photos are large — NAS has the capacity and is already your backup target |
| PostgreSQL database | Longhorn via CNPG | Small, latency-sensitive, needs reliability |
| ML model cache | Longhorn | ~2-4GB, benefits from fast SSD on pod restarts |
| Redis job queue | Longhorn | Tiny, ephemeral |

### Why NFS for photos

Your 3 nodes have 512GB SSDs each. A typical photo library is hundreds of GB and grows continuously. Storing it on Longhorn would replicate it 2× across your SSDs — they would fill up quickly. The NAS is designed for this: large capacity, already backed up, accessible from other devices.

NFS latency has no meaningful impact on Immich — face detection and CLIP embeddings are CPU/RAM-bound, not disk-bound.

### PostgreSQL with pgvecto.rs

Immich uses PostgreSQL with the **pgvecto.rs** extension for vector similarity search (the engine behind face clustering and semantic search). Standard PostgreSQL won't work. The `immich-postgres` CNPG Cluster uses the `cloudnative-pgvecto.rs` custom image, which has the extension pre-installed — same CNPG operator, different image.

### Required `cluster.yaml` field

```yaml
nfs_photos_path: "/volume1/photos"   # NFS export for Immich on your NAS
```

Immich creates its own subdirectory structure inside the share on first run (`library/`, `thumbs/`, `encoded/`, `upload/`).

### Access

Immich is on the **external** gateway — accessible at `https://immich.yourdomain.com` from both your home network and the internet. This lets the Immich mobile app back up photos over mobile data when you're away from home. Cloudflare Tunnel handles the external routing without any port-forwarding.

---

## Layer 10: Cloud Storage — Nextcloud

Nextcloud is a self-hosted alternative to Google Drive / iCloud / Dropbox. It provides file sync across devices, a web UI for browsing files, calendar, contacts, and a large ecosystem of apps. It runs in the `cloud` namespace.

### Storage split

| What | Where | Why |
|---|---|---|
| Nextcloud code + config | Longhorn 10Gi | App installation, `config/config.php`, installed apps, themes |
| User data (files) | `nfs-nextcloud` (NAS) | All uploaded files live here — mounts `/nextcloud` share root |
| PostgreSQL database | Longhorn via CNPG | Metadata, sharing records, activity log |
| Redis | Longhorn 1Gi | File locking and session cache — required for correct operation |

### How the storage layout works

Nextcloud's container has two volume mounts that overlap intentionally:

```
/var/www/html          ← Longhorn PVC (Nextcloud code + config)
/var/www/html/data     ← NFS PVC (user files, mounted on top)
```

Kubernetes allows this — the NFS mount at `/data` takes precedence over the Longhorn mount at that subdirectory. Nextcloud sees `config/config.php` on Longhorn and all user files on NFS. The two storage systems never interfere.

### Existing NAS data

The `nfs-nextcloud` StorageClass mounts the `/nextcloud` NAS share root **without creating any subdirectories**. If you already have Nextcloud data on the NAS, it will be visible immediately when the PVC is bound. `reclaimPolicy: Retain` on the StorageClass ensures that deleting the PVC in Kubernetes never touches the NAS files.

If you're migrating from an existing Nextcloud instance, you'll also need to restore the database dump to the new CNPG cluster, and run `php occ files:scan --all` once to rebuild the file index.

### Background jobs (cron)

Nextcloud requires periodic background processing for notifications, sharing expiry, preview generation, and housekeeping. A Kubernetes `CronJob` runs `php cron.php` inside the same container image every 5 minutes. It mounts the same Longhorn and NFS volumes so it has full access to config and user data.

### Access

Nextcloud is on the **external** gateway — accessible at `https://nextcloud.yourdomain.com` from both your home network and the internet. This is needed for the Nextcloud desktop and mobile sync clients to work when you're away from home. Cloudflare Tunnel handles the external routing.

### Required `cluster.yaml` fields

```yaml
nfs_nextcloud_path: "/nextcloud"       # NFS export for user data
nextcloud_admin_password: "strongpassword"
```

---

## Layer 11: Observability Stack

The observability namespace gives you full visibility into the cluster — metrics, logs, disk health, uptime, and at-a-glance status badges. Seven apps work together as a pipeline.

### How they connect

```
Disks       → smartctl-exporter ──────────────────────┐
Nodes       → node-exporter ──────────────────────────┤
K8s objects → kube-state-metrics ─────────────────────┤→ Prometheus
App metrics → /metrics endpoints ─────────────────────┘      │
                                                              │
Container logs → Fluent Bit ──────────────────→ Loki         │
                                                    │         │
                                                    └─────────┴→ Grafana (dashboards)

                              Gatus ← polls all service URLs (status page)
                              Kromgo ← queries Prometheus → serves metric badges
```

### kube-prometheus-stack

The foundation of the metrics pipeline. One Helm chart installs:
- **Prometheus** — scrapes and stores metrics from everything in the cluster. Retention: 14 days, 20Gi on Longhorn
- **Alertmanager** — routes alerts to notification channels (email, Slack, etc.). 1Gi on Longhorn
- **node-exporter** — DaemonSet on every node, exposes CPU, RAM, disk I/O, network
- **kube-state-metrics** — exposes Kubernetes object state: pod status, deployment replicas, PVC capacity, node conditions

`serviceMonitorSelectorNilUsesHelmValues: false` is set so Prometheus picks up **all** ServiceMonitors in the cluster automatically — every app that adds a `ServiceMonitor` gets scraped without touching the Prometheus config.

Grafana is **disabled** inside this chart and deployed separately for full config control.

### Grafana

Standalone Grafana connected to both Prometheus and Loki as data sources out of the box — no manual UI configuration needed. Four community dashboards are imported on first boot:

| Dashboard | What it shows |
|---|---|
| Kubernetes cluster overview (7249) | Pod counts, resource requests vs limits across namespaces |
| Node exporter full (1860) | Per-node CPU, RAM, disk I/O, network throughput |
| Flux CD cluster | GitOps reconciliation status, HelmRelease health |
| Longhorn (16888) | Volume health, replica counts, storage capacity |

### Loki

Log aggregation for the whole cluster. Runs in **single-binary** mode (one pod, simpler than the scalable/microservices mode — ideal for a home lab). Logs are stored on a 10Gi Longhorn PVC and retained for 30 days.

### Fluent Bit

DaemonSet (one pod per node) that tails `/var/log/containers/*.log` on each node and ships every container's stdout/stderr to Loki. Each log line is enriched with Kubernetes metadata (namespace, pod name, container name) so you can filter in Grafana with queries like:

```
{namespace="immich", container="server"}
```

Noisy health-check and readiness probe lines are dropped before shipping to keep log volume low.

### smartctl-exporter

DaemonSet (one pod per node) that runs `smartctl` against every block device on the host and exposes S.M.A.R.T. disk health data as Prometheus metrics. On the HP EliteDesk 800 G3 this covers the 512GB SSD in each node. A `ServiceMonitor` tells Prometheus to scrape it every 5 minutes.

Requires `privileged: true` and a `/dev` host mount to access raw disk devices.

### Gatus

Health/uptime monitoring with a clean status page. Checks each configured endpoint on a schedule (every 5 minutes by default) and stores pass/fail history in a SQLite database on Longhorn. Pre-configured endpoints cover all your exposed apps. Results are visible at `https://gatus.yourdomain.com`.

Add new endpoints by editing the `config.yaml` section in `gatus/app/helmrelease.yaml.j2`.

### Kromgo

Tiny HTTP server that queries Prometheus and serves individual metric values as plain-text responses — designed for embedding in a GitHub README as shield.io badges:

```
![Nodes](https://img.shields.io/endpoint?url=https://kromgo.yourdomain.com/cluster_node_count)
![CPU](https://img.shields.io/endpoint?url=https://kromgo.yourdomain.com/cluster_cpu_usage)
```

Pre-configured metrics: node count, CPU usage %, memory usage %, running pod count.

### Dependency ordering

```
loki              (wait: true) ←── fluent-bit
                                └── grafana
kube-prometheus-stack (wait: true) ←── grafana
                                   └── smartctl-exporter
                                   └── kromgo
gatus             (no deps — polls HTTP, not Prometheus)
```

### Required `cluster.yaml` field

```yaml
grafana_admin_password: "strongpassword"
```

---

## Layer 12: Media Stack — Entertainment Namespace

The `entertainment` namespace runs a self-hosted media pipeline that mirrors the classic *arr stack, lifted from Docker into Kubernetes.

### The full pipeline

```
Autobrr ──────────────────────── automates torrent releases from RSS feeds
    │
    ↓
Transmission ──────────────────── downloads torrents to Longhorn (local SSD)
    │
    ↓ (completed download)
Radarr  (movies) ─┐
Sonarr  (TV shows) ┤── scans /downloads, imports to NFS /media, notifies Jellyfin
    │
    └─── queries Jackett ──────── torrent tracker aggregator / proxy
             │
             └─── queries FlareSolverr ── Cloudflare bypass for Jackett trackers

Recyclarr ────────────────────── syncs TRaSH Guide quality profiles to Radarr/Sonarr

Jellyseerr ───────────────────── request portal — users discover and request content
    │
    ↓
Jellyfin ─────────────────────── streams finished media to devices
```

### App summary

| App | Port | Gateway | Image |
|---|---|---|---|
| Jellyfin | 8096 | external | `ghcr.io/jellyfin/jellyfin` |
| Jellyseerr | 5055 | external | `ghcr.io/fallenbagel/jellyseerr` |
| Autobrr | 7474 | internal | `ghcr.io/autobrr/autobrr` |
| Transmission | 9091 | internal | `lscr.io/linuxserver/transmission` |
| Radarr | 7878 | internal | `ghcr.io/home-operations/radarr` |
| Sonarr | 8989 | internal | `ghcr.io/home-operations/sonarr` |
| Jackett | 9117 | internal (ClusterIP) | `lscr.io/linuxserver/jackett` |
| FlareSolverr | 8191 | internal (ClusterIP) | `ghcr.io/flaresolverr/flaresolverr` |
| Recyclarr | — | none (CronJob) | `ghcr.io/recyclarr/recyclarr` |

### Storage design

| What | Where | Why |
|---|---|---|
| App config for each *arr app | Longhorn (per-app PVC) | Small, needs fast SSD on startup |
| Active downloads | `media-downloads` Longhorn 200Gi | Fast local SSD during download; freed after import |
| Finished media (movies, TV) | `nfs-media` NAS | NAS has the capacity; accessible from Jellyfin clients |

The `media-downloads` PVC is a **single shared Longhorn PVC** mounted by Transmission (writer), Radarr, and Sonarr (readers after completion).

### Why downloads stay on Longhorn and not NFS

| | NFS downloads | Longhorn downloads |
|---|---|---|
| Download speed | Limited by network + NAS I/O | Local SSD, full throughput |
| Hardlinking after import | Works (same filesystem) | Not possible (different filesystem) |
| Space freed after import | Only if you delete | Radarr/Sonarr copy-then-delete |
| NAS load | Continuous write during download | Only a single copy at import time |

For a home lab the copy-then-delete trade-off is fine. The NAS only stores clean, organised media — it never sees torrent temp files.

### Node pinning — the ReadWriteOnce constraint

The `media-downloads` Longhorn PVC is `ReadWriteOnce`, meaning **only one Kubernetes node can mount it at a time**. Transmission, Radarr, and Sonarr all need access to the same PVC simultaneously, so they must all run on the same node.

This is enforced via a `nodeSelector` in each app's HelmRelease:

```yaml
pod:
  nodeSelector:
    media-node: "true"
```

Before deploying, label one of your three nodes:

```bash
kubectl label node <node-name> media-node=true
```

Jellyfin, Jellyseerr, Jackett, Autobrr, and FlareSolverr have no such constraint — they can run on any node.

### Import settings in Radarr and Sonarr

Because downloads (Longhorn) and the media library (NFS) are **different filesystems**, Radarr and Sonarr cannot hardlink files on import. They will copy the file from `/downloads` to `/media/movies` or `/media/tv`, then delete the original.

In the Radarr/Sonarr UI, set:
- **Settings → Media Management → File Management → Import Mode** → `Copy` (not `Hardlink`)
- **Root folder** → `/media/movies` (Radarr) or `/media/tv` (Sonarr)

### Recyclarr — two-step bootstrap

Recyclarr's config is a SOPS-encrypted secret rendered from `cluster.yaml` via
`task template:render`. The API keys it needs (`recyclarr_radarr_api_key`,
`recyclarr_sonarr_api_key`) only exist after Radarr and Sonarr have started — so
this follows the same two-commit pattern as the Forgejo runner token and Garage
credentials:

1. **First commit** — leave both keys empty in `cluster.yaml`, render and commit.
   Flux deploys the full stack. Recyclarr's first CronJob run will fail with
   "invalid API key" — expected and harmless; nothing else depends on it.
2. Radarr UI → Settings → General → copy API Key
3. Sonarr UI → Settings → General → copy API Key
4. **Second commit** — paste both keys into `cluster.yaml`, re-render,
   re-SOPS-encrypt `recyclarr/app/secret.sops.yaml`, commit.
5. Flux reconciles the updated secret. The next CronJob run syncs successfully.

### Configuring Recyclarr

The `recyclarr.yml` config is stored as a SOPS secret (`recyclarr/app/secret.sops.yaml`). It ships with a minimal skeleton. Edit it to add the quality profiles and custom formats you want — the [TRaSH Guides](https://trash-guides.info) document every option.

### Required `cluster.yaml` fields

```yaml
nfs_media_path: "/videos"        # NAS share root — must contain movies/ and tv/ subdirs
recyclarr_radarr_api_key: ""     # filled in after Radarr deploys
recyclarr_sonarr_api_key: ""     # filled in after Sonarr deploys
```

---

## Layer 13: How traffic gets in — The Networking Stack

This is often the most confusing part for juniors. Here's the full journey of a request from the internet to your app:

```
Browser (internet)
  → Cloudflare DNS resolves your domain
  → Cloudflare Tunnel (cloudflared pod in cluster)
  → Envoy Gateway (external)
  → Your app pod
```

For traffic on your home network:

```
Your laptop (home network)
  → Your router/DNS points *.yourdomain.com to cluster DNS IP
  → k8s_gateway resolves the name to Envoy Gateway IP
  → Envoy Gateway (internal)
  → Your app pod
```

The key insight: **there is no port-forwarding on your router**. Cloudflare Tunnel creates an outbound connection from inside the cluster to Cloudflare's edge — so inbound internet traffic piggybacks on that tunnel. Much more secure.

---

## Layer 14: Secrets Management — SOPS + age

You can't just put passwords and API keys in Git — everyone can read your repo. The solution here is **SOPS** (Secrets OPerationS):

- Secrets are encrypted with **age** (a modern encryption tool) before being committed
- Only someone with the `age.key` file can decrypt them
- Flux knows the key and decrypts secrets before applying them

So a file like `cluster-secrets.sops.yaml` in Git looks like garbled cipher text, but Flux sees the real values at deploy time.

---

## Layer 15: The Template System

The repo uses **Jinja2 templates** (common in Ansible, Python world). Files ending in `.j2` are templates — they contain placeholders like `#{ cluster.name }#` that get replaced with values from your `cluster.yaml` and `nodes.yaml`.

You fill in:
- `cluster.yaml` — your domain, IP ranges, GitHub repo URL
- `nodes.yaml` — your actual hardware (MAC addresses, disk paths, CPU count)

Then you run `task bootstrap:generate` and it renders all the real config files from those templates.

---

## Layer 16: Automation — Taskfile & CI/CD

**Taskfile.yaml** is like a `Makefile` but more readable. Instead of remembering long commands, you run things like:

```bash
task bootstrap:generate   # render templates
task talos:apply          # push config to nodes
task bootstrap:flux       # install Flux into the cluster
```

**GitHub Actions** handles CI:
- `flux-local.yaml` — validates your Kubernetes manifests on every PR (catches errors before they hit the cluster)
- `release.yaml` — auto-cuts monthly releases
- **Renovate** — a bot that opens PRs to keep all your tool versions up to date automatically

---

## The Bootstrap Sequence — How you go from zero to running cluster

1. Fill in `cluster.yaml` and `nodes.yaml` with your hardware details
2. Run templates to generate all configs
3. Boot your machines with Talos, push Talos config to them
4. Bootstrap Kubernetes (`talosctl bootstrap`)
5. Run `helmfile` to install core components (Cilium, CoreDNS, cert-manager, Flux)
6. Flux takes over — it reads Git and deploys everything else

After step 6, the cluster is **self-managing**. You just commit changes to Git.

---

## Key Mental Model

> **The cluster is a reflection of this Git repository.**
> The repo is the source of truth. The cluster converges to match it.
> If something breaks, the fix is a Git commit — not `kubectl` wizardry.

---

## What to read next

If you want to go deeper, recommended reading order:

1. `README.md` — the full deployment guide
2. `cluster.sample.yaml` + `nodes.sample.yaml` — understand what you need to configure
3. `kubernetes/apps/network/` — the networking stack is the hardest part, worth studying
4. `kubernetes/apps/storage/` — Longhorn and NFS CSI driver configuration
5. `templates/kubernetes/flux/` — see how Flux is bootstrapped
6. `.taskfiles/` — understand what each `task` command does
