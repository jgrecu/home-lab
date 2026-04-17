# Cluster Migration Guide: Raspberry Pi → ThinkCentre

## Overview

This guide covers migrating from the current Raspberry Pi 4 cluster (1 controller + 4 workers) to a new cluster with ThinkCentre hardware (1 CP, 2 workers: Core i5 3.2 GHz, 512GB SSD, 16GB RAM).

## Current Setup Summary

### Hardware
- **Controller**: rpi-ctrl (192.168.1.50)
- **Workers**: rpi-wrk1, rpi-wrk2, rpi-wrk3, rpi-wrk4 (192.168.1.51-54)
- **Storage**: ~55GB per node
- **RAM**: Limited (Raspberry Pi 4)

### Key Configurations
- **NAS**: 192.168.1.37 (NFS share at `/videos`)
- **Media Node**: rpi-wrk2 (labeled `media-node=true`)
- **API VIP**: 192.168.1.55
- **Network Range**: 192.168.1.0/24

### Deployed Services

#### Downloads Namespace (Media Management)
- **Transmission**: 4.1.1 (on rpi-wrk2)
- **Radarr**: 6.1.1 (on rpi-wrk2) → `/videos/Films`
- **Sonarr**: 4.0.17 (on rpi-wrk2) → `/videos/Series`
- **Jackett**: v0.24.1601-ls374
- **Autobrr**: v1.76.0
- **Flaresolverr**: v3.4.6
- **Recyclarr**: 8.5.1

**Storage**:
- `media-downloads`: 20Gi Longhorn PVC (1 replica, RWO)
- `radarr-media` / `sonarr-media`: 1Ti NFS PVC (RWX)

#### Entertainment Namespace (Media Services)

**Currently Deployed on RPi**:
- **Seerr**: v3.1.1 (hotio image) - ✅ Running (1/1 Ready)
  - Internal access only (envoy-internal gateway)
  - 2Gi Longhorn PVC for config + SQLite
  - Homepage integration enabled

**Configured but Blocked by Resource Constraints on RPi**:
- **Immich**: v2.7.5 - ❌ CNPG PostgreSQL cluster cannot create volumes (Longhorn faulting)
  - Uses CloudNative-PG for PostgreSQL database
  - Uses Dragonfly for Redis cache (database-system namespace)
  - Uses static PV for photo library (NFS `/immich/library`)
  - Machine learning cache on Longhorn (10Gi)
  - External access via envoy-external gateway
  
- **Jellyfin**: 10.11.8 - ❌ Insufficient memory to schedule on RPi cluster
  - Reduced memory limits (2Gi) for RPi compatibility
  - Uses static PV for media library (NFS `/videos`, shared with Radarr/Sonarr)
  - Uses Longhorn for config/metadata (10Gi)
  - External access via envoy-external gateway

- **Kavita**: 0.8.9 (official Kareadita image) - ❌ Longhorn cannot attach volumes (node readiness issues)
  - Uses static PV for book library (NFS `/books`)
  - Uses Longhorn for config/cache (10Gi)
  - Internal access only (envoy-internal gateway)

**Post-Migration Status**: All entertainment apps are properly configured in Git and will deploy successfully on ThinkCentre hardware (16GB RAM, 512GB SSD). Only resource exhaustion on RPi cluster is blocking Immich, Jellyfin, and Kavita.

**NFS Storage Architecture**: All NFS-backed PVCs now use static PersistentVolumes pointing directly to existing NAS directory structures (no more `pvc-*` subdirectories from dynamic provisioning).

#### Home Automation Namespace
- **Home Assistant**: 2025.12.5 - Smart home automation platform
  - Uses CNPG PostgreSQL database (2 instances, 10Gi)
  - 5Gi Longhorn PVC for config, automations, scripts
  - Internal access only (envoy-internal gateway)
  - Homepage integration enabled
  - Volsync daily backups to Garage

#### Cloud Namespace
- **Nextcloud**: 30.0.17-apache - Private cloud file sync and sharing
  - Uses CNPG PostgreSQL database (2 instances, 10Gi)
  - Uses shared Dragonfly instance for caching/locking
  - 10Gi Longhorn PVC for installation/config
  - 1Ti NFS PVC for user data (on NAS `/nextcloud`)
  - External access via envoy-external gateway
  - Homepage integration enabled
  - Volsync daily backups to Garage (html PVC only)

#### Forgejo Namespace
- **Forgejo**: Git forge with Actions CI/CD - Self-hosted GitHub alternative
  - Uses CNPG PostgreSQL database (2 instances, 5Gi)
  - 20Gi Longhorn PVC for repositories, LFS, packages, artifacts
  - External access via envoy-external gateway
  - Built-in container registry enabled
  - Homepage integration enabled
  - Volsync daily backups to Garage
- **Forgejo Runner**: 6.4.0 (2 replicas) - GitHub Actions-compatible CI/CD runners
  - Requires manual registration token after Forgejo first deploys
  - Supports `ubuntu-latest` and `ubuntu-22.04` labels

#### Database System
- **CloudNative-PG**: PostgreSQL operator with Garage S3 backups
  - Manages databases for: Immich, Home Assistant, Nextcloud, Forgejo
  - Barman continuous WAL archiving (180-day retention)
- **Dragonfly**: Redis-compatible cache (v1.38.0)
  - Used by: Immich (job queues), Nextcloud (file locking/sessions)

#### Storage System
- **Longhorn**: Block storage with 2 replicas
- **Garage**: S3-compatible object storage for backups (already bootstrapped)
  - Buckets: `longhorn-backups`, `cnpg-backups`, `volsync-backups`
- **NFS CSI Driver**: For media library access
- **Volsync**: Automated PVC backups to Garage S3
  - Daily backups: Homepage (3:15 AM), Home Assistant (2 AM), Nextcloud (1 AM), Forgejo (3 AM)
  - Daily backups: Immich DB (2:30 AM), Kavita (3 AM), Grafana (3:30 AM)
  - Retention: 7 daily, 8 weekly, 6 monthly snapshots (~6 months)
  - Uses Restic with deduplication for efficient storage

---

## ✅ What Will Transfer Successfully

### 1. All Application Configurations
- Entire `kubernetes/` directory
- All Helm charts and manifests
- SOPS-encrypted secrets (using same age key)

### 2. GitOps Approach
- Flux setup and structure
- Kustomizations and dependencies
- Renovate integration for version updates

### 3. Container Images
- LinuxServer.io images support both ARM64 and AMD64
- All images are multi-arch compatible

### 4. Network Configuration
- LoadBalancer setup (Cilium)
- Gateway API / HTTPRoutes
- Cloudflare tunnel integration

---

## ⚠️ Configuration Changes Required

### 1. Talos Configuration

**File**: `talos/talconfig.yaml`

Update for new hardware:
- Node count: 1 controller + 2 workers (vs current 1+4)
- Hostnames: Update to match new machines
- IP addresses: Choose new IPs in your network range
- MAC addresses: Update `hardwareAddr` for each node
- Keep existing patches from `talos/patches/`

**Add media-node label to chosen worker**:
```yaml
  - hostname: "thinkcentre-wrk1"
    ipAddress: "192.168.1.X"
    nodeLabels:
      media-node: "true"  # Add this for media services
```

### 2. Cluster Network Configuration

**File**: `cluster.yaml`

Update these values:
```yaml
# Network CIDR (if changing)
node_cidr: "192.168.1.0/24"

# Choose new IPs for cluster services
cluster_api_addr: "192.168.1.XX"      # Current: 192.168.1.55
cluster_dns_gateway_addr: "192.168.1.XX"  # Current: 192.168.1.56
cluster_gateway_addr: "192.168.1.XX"      # Current: 192.168.1.57
cloudflare_gateway_addr: "192.168.1.XX"   # Current: 192.168.1.58
pihole_dns_addr: "192.168.1.XX"           # Current: 192.168.1.60

# NFS server (update if NAS IP changes)
nfs_server_addr: "192.168.1.37"
nfs_media_path: "/videos"

# Garage S3 credentials (keep existing or regenerate)
garage_s3_access_key_id: "GKedd0423c806afe8e64a7936e"
garage_s3_secret_access_key: "736b93e36e09c989cd9d960169f22d8730dca8142d58b5085bd9bd9871420ab9"
```

### 3. Storage Sizes (Recommended Increases)

With 512GB SSD available, increase these sizes:

**File**: `templates/config/kubernetes/apps/downloads/downloads-pvc.yaml.j2`
```yaml
# Current: 20Gi → Recommended: 100Gi
storage: 100Gi  # More buffer for concurrent downloads
```

**File**: `templates/config/kubernetes/apps/database-system/dragonfly-instance/app/dragonfly.yaml.j2`
```yaml
# Current: 256Mi RAM → Recommended: 1-2Gi
resources:
  requests:
    cpu: 200m      # Increase from 100m
    memory: 1Gi    # Increase from 256Mi
  limits:
    cpu: 1000m     # Increase from 500m
    memory: 2Gi    # Increase from 512Mi
```

**File**: `templates/config/kubernetes/apps/entertainment/jellyfin/app/helmrelease.yaml.j2`
```yaml
# Currently reduced for RPi: 2Gi limit
# Recommended for ThinkCentre: 4Gi limit
resources:
  limits:
    memory: 4Gi  # Increase from 2Gi for better performance
```

**File**: `templates/config/kubernetes/apps/entertainment/immich/app/helmrelease.yaml.j2`
```yaml
# Machine learning cache - can optionally increase from 10Gi to 20Gi
machine-learning:
  persistence:
    cache:
      size: 20Gi  # More space for ML models (optional)
```

**Optional - Longhorn default replicas**:
Keep `media-downloads` at 1 replica (it's just a buffer), but could increase default Longhorn replicas to 2 for better redundancy on new hardware.

### 4. Node Selection for Media Services

**Decision**: Which worker node hosts media services?

With only 2 workers, choose the one with:
- Better local storage performance
- Connected to same network switch as NAS (for NFS performance)

Then label it: `kubectl label node <chosen-worker> media-node=true`

---

## 🚀 Migration Process

### Phase 1: Clean Up and Prepare Configuration

1. **Backup Current Cluster State**:
```bash
cd /Users/I337469/Downloads/talos-rpi4/home-lab

# Commit current state
git add -A
git commit -m "backup: final RPi4 cluster state before ThinkCentre migration"
git push

# Backup age key to secure location
cp age.key ~/Desktop/age.key.backup.$(date +%Y%m%d)
```

2. **Reset Generated Files**:
```bash
# Clean up all generated files from RPi4 setup
task template:reset

# This removes:
# - talos/clusterconfig/ (node configs)
# - talos/talsecret.yaml (cluster secrets)
# - talos/talconfig.yaml (generated from template)
# - kubernetes/ (all generated manifests)
# - bootstrap/ (bootstrap scripts)
# - kubeconfig, talosconfig (cluster access files)
```

3. **Generate x86_64 Talos Schematic**:

Visit https://factory.talos.dev/ and:
- Select Talos version: **v1.12.6** (match current version)
- Select architecture: **amd64** (x86_64)
- Select platform: **metal** (bare metal)
- Select system extensions:
  - `iscsi-tools` - Required for Longhorn storage
  - `intel-ucode` - Intel CPU microcode updates
  - `i915-ucode` - Intel GPU microcode (optional, for integrated graphics)

Click "Generate Schematic" and **copy the 64-character schematic ID**.

Download the ISO:
```bash
export SCHEMATIC_ID="YOUR_SCHEMATIC_ID_HERE"
curl -LO "https://factory.talos.dev/image/${SCHEMATIC_ID}/v1.12.6/metal-amd64.iso"
```

Flash to USB drive (macOS):
```bash
# Find USB drive
diskutil list

# Unmount (replace diskN with your USB drive number)
diskutil unmountDisk /dev/diskN

# Write ISO
sudo dd if=metal-amd64.iso of=/dev/rdiskN bs=1m

# Eject
diskutil eject /dev/diskN
```

4. **Boot ThinkCentre Machines into Maintenance Mode**:

For each machine (you can reuse the same USB stick):
1. Insert USB drive with Talos ISO
2. Power on and enter BIOS (F1 or F12)
3. Set boot order: USB first
4. Boot from USB
5. Machine boots into Talos maintenance mode (listening on port 50000)
6. **Remove USB stick once booted** - maintenance mode runs from RAM
7. Reuse USB stick for next machine

Discover machines on network:
```bash
nmap -Pn -n -p 50000 192.168.1.0/24 -vv | grep 'Discovered'
```

5. **Collect Hardware Information**:

For each machine, get disk and MAC information:
```bash
# Get disk information (replace X with actual IP from nmap)
talosctl get disks -n 192.168.1.X --insecure

# Get MAC address
talosctl get links -n 192.168.1.X --insecure
```

Record in table format:

| Machine | Role | Temp IP | Final IP | Disk Path | MAC Address | Hostname |
|---------|------|---------|----------|-----------|-------------|----------|
| 1 | Controller | 192.168.1.X | 192.168.1.50 | /dev/sda or /dev/nvme0n1 | aa:bb:cc:dd:ee:ff | tc-ctrl |
| 2 | Worker | 192.168.1.Y | 192.168.1.51 | /dev/sda or /dev/nvme0n1 | 11:22:33:44:55:66 | tc-wrk1 |
| 3 | Worker | 192.168.1.Z | 192.168.1.52 | /dev/sda or /dev/nvme0n1 | 77:88:99:aa:bb:cc | tc-wrk2 |

6. **Update Configuration Files**:

**Generate config files from samples**:
```bash
# If starting fresh, generate from sample files
task init
```

**Edit nodes.yaml**:
```bash
vim nodes.yaml
```

Replace entire `nodes:` section with your new hardware:
```yaml
---
nodes:
  - name: "tc-ctrl"
    address: "192.168.1.50"
    controller: true
    disk: "/dev/sda"  # or /dev/nvme0n1 from hardware discovery
    mac_addr: "aa:bb:cc:dd:ee:ff"  # from hardware discovery
    schematic_id: "YOUR_NEW_SCHEMATIC_ID"  # from factory.talos.dev
  - name: "tc-wrk1"
    address: "192.168.1.51"
    controller: false
    disk: "/dev/sda"
    mac_addr: "11:22:33:44:55:66"
    schematic_id: "YOUR_NEW_SCHEMATIC_ID"
    media_node: true  # for Transmission, Radarr, Sonarr
  - name: "tc-wrk2"
    address: "192.168.1.52"
    controller: false
    disk: "/dev/sda"
    mac_addr: "77:88:99:aa:bb:cc"
    schematic_id: "YOUR_NEW_SCHEMATIC_ID"
```

**Review cluster.yaml**:
```bash
vim cluster.yaml
```

Keep existing network IPs and credentials, or update as needed:
- `cluster_api_addr`, `cluster_dns_gateway_addr`, etc.
- Garage S3 credentials (will be regenerated during bootstrap)
- NFS server address

Optional: Increase storage sizes for 512GB SSDs:
```bash
vim templates/config/kubernetes/apps/downloads/downloads-pvc.yaml.j2
# Change: 20Gi → 100Gi
```

7. **Regenerate All Configurations**:
```bash
# Template out kubernetes and talos configuration files
task configure

# Or with auto-approval:
task configure --yes
```

Expected output:
- ✓ Validated cluster.yaml and nodes.yaml schemas
- ✓ Rendered ~127 templates
- ✓ Generated Talos configs for 3 nodes
- ✓ Encrypted secrets with SOPS
- ✓ Validated Kubernetes manifests

Verify generated configs:
```bash
# Check generated Talos config
cat talos/talconfig.yaml | grep -A 20 "nodes:"

# Verify node configs exist
ls -l talos/clusterconfig/
# Should show: tc-ctrl.yaml, tc-wrk1.yaml, tc-wrk2.yaml, talosconfig

# Verify schematic IDs
grep "talosImageURL" talos/talconfig.yaml
```

8. **Commit Changes**:
```bash
git add -A
git diff --cached  # Review
git commit -m "feat: migrate cluster from RPi4 to ThinkCentre x86_64

- Update nodes.yaml with 3 ThinkCentre machines (1 ctrl, 2 workers)
- Generate new x86_64 schematic with Intel extensions
- Keep same IP addresses and network configuration
- Label tc-wrk1 as media-node
- Schematic ID: YOUR_NEW_SCHEMATIC_ID"

git push
```

### Phase 2: Bootstrap New Cluster

1. **Bootstrap Talos**:

Install Talos to all nodes (controller + workers):

```bash
cd /Users/I337469/Downloads/talos-rpi4/home-lab

# Bootstrap Talos cluster
task bootstrap:talos
```

**What this does:**
1. Generates Talos secrets (if not already present)
2. Applies configuration to all nodes (controller + workers)
3. Waits for nodes to install Talos to disk and reboot
4. Bootstraps etcd on the controller
5. Retrieves kubeconfig
6. Merges talosconfig for easier management

**Monitor progress:**
```bash
# Watch nodes boot and join
talosctl --nodes 192.168.1.50 dmesg --follow --insecure

# Check all nodes joined
export KUBECONFIG=/Users/I337469/Downloads/talos-rpi4/home-lab/kubeconfig
kubectl get nodes -w
```

Expected: All 3 nodes shown as `NotReady` (CNI not deployed yet)

2. **Commit Encrypted Secrets**:
```bash
# Push the generated encrypted secrets to git
git add -A
git commit -m "chore: add talhelper encrypted secret :lock:"
git push
```

3. **Bootstrap Kubernetes Applications**:

Deploy Cilium (CNI), CoreDNS, Spegel, Flux, and sync all cluster applications:

```bash
# Install cilium, coredns, spegel, flux and sync the cluster
task bootstrap:apps
```

**What this does:**
1. Installs Flux CRDs and controllers
2. Deploys SOPS secrets (GitHub deploy key, age key)
3. Creates GitRepository pointing to your repo
4. Deploys Cilium CNI (nodes become Ready)
5. Deploys CoreDNS
6. Deploys Spegel (local registry mirror)
7. Deploys root Kustomization (recursively deploys all apps)

**Monitor deployment:**
```bash
# Watch all pods come up
kubectl get pods --all-namespaces --watch

# Or watch Flux kustomizations
flux get kustomizations --watch
```

**Timeline (10-15 minutes):**
- Flux system: 1-2 min
- Cilium CNI: 2-3 min (nodes become Ready)
- CoreDNS: 1-2 min
- Spegel: 2-3 min
- Cert-manager: 2-3 min
- Longhorn storage: 5-10 min
- Garage S3: 3-5 min
- CNPG operator: 2-3 min (after Garage)
- Database clusters: 5-10 min (after CNPG)
- All other applications: 5-10 min

4. **Wait for Core Infrastructure**:
```bash
# Wait for nodes to become Ready (Cilium deployed)
kubectl wait --for=condition=ready nodes --all --timeout=600s

# Verify media-node label
kubectl get nodes --show-labels | grep media-node

# Wait for storage
kubectl wait --for=condition=ready pod -n storage -l app.kubernetes.io/name=longhorn-manager --timeout=600s
kubectl wait --for=condition=ready pod -n storage -l app.kubernetes.io/name=csi-driver-nfs --timeout=600s

# Check storage classes
kubectl get storageclass
```

5. **Bootstrap Garage S3 Storage**:

**Important**: Garage must be bootstrapped before CNPG can start, as CNPG depends on Garage for WAL archiving.

```bash
# Wait for Garage pod to be running
kubectl wait --for=condition=ready pod -n storage -l app.kubernetes.io/name=garage --timeout=300s

# Bootstrap Garage (creates layout, buckets, and S3 keys)
task storage:bootstrap-garage

# This will:
# 1. Configure Garage cluster layout
# 2. Create buckets (longhorn-backups, cnpg-backups, volsync-backups)
# 3. Generate S3 access keys
# 4. Update cluster.yaml with new credentials
# 5. Regenerate configs with new credentials

# After bootstrap completes, commit the updated credentials
git add cluster.yaml kubernetes/ bootstrap/
git commit -m "chore: update Garage S3 credentials after bootstrap"
git push

# Force Flux to reconcile with new credentials
flux reconcile kustomization cluster-apps --with-source
```

6. **Verify Application Deployment**:
```bash
# Check all pods
kubectl get pods -A

# Check for failures
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### Phase 3: Verify Applications

1. **Check All Namespaces**:
```bash
# Overview
kubectl get pods -A

# Check specific namespaces
kubectl get pods -n downloads
kubectl get pods -n entertainment
kubectl get pods -n home-automation
kubectl get pods -n cloud
kubectl get pods -n forgejo
kubectl get pods -n database-system
kubectl get pods -n storage
kubectl get pods -n observability
kubectl get pods -n network
```

2. **Verify Media Services Node Placement**:
```bash
# Confirm transmission, radarr, sonarr are on media-node
kubectl get pods -n downloads -o wide | grep -E "transmission|radarr|sonarr"

# Should show your labeled worker node
```

3. **Test Media Stack**:
```bash
# Port-forward to test download services
kubectl port-forward -n downloads svc/radarr 7878:7878
kubectl port-forward -n downloads svc/sonarr 8989:8989
kubectl port-forward -n downloads svc/transmission-app 9091:9091

# Port-forward to test entertainment services
kubectl port-forward -n entertainment svc/seerr-app 5055:5055
kubectl port-forward -n entertainment svc/immich 2283:2283
kubectl port-forward -n entertainment svc/jellyfin-app 8096:8096
kubectl port-forward -n entertainment svc/kavita-app 5000:5000

# Port-forward to test home automation
kubectl port-forward -n home-automation svc/home-assistant 8123:8123

# Port-forward to test cloud services
kubectl port-forward -n cloud svc/nextcloud 80:80

# Port-forward to test Forgejo
kubectl port-forward -n forgejo svc/forgejo 3000:3000

# Open in browser: http://localhost:7878 (Radarr)
# Verify:
# - Root folder shows /media/Films
# - Transmission is connected
# - Can search indexers via Jackett

# Open in browser: http://localhost:5055 (Seerr)
# Open in browser: http://localhost:2283 (Immich)
# Open in browser: http://localhost:8096 (Jellyfin)
# Open in browser: http://localhost:5000 (Kavita)
# Open in browser: http://localhost:8123 (Home Assistant)
# Open in browser: http://localhost (Nextcloud)
# Open in browser: http://localhost:3000 (Forgejo)
```

4. **Verify NFS Mounts**:
```bash
# Check if media PVCs are bound
kubectl get pvc -n downloads
kubectl get pvc -n entertainment
kubectl get pvc -n cloud

# Exec into pods to verify NFS mounts
kubectl exec -n downloads deploy/radarr -- ls -la /media
# Should show: Films/ and Series/

kubectl exec -n entertainment deploy/jellyfin -- ls -la /media
# Should show: Films/ and Series/

kubectl exec -n entertainment deploy/immich-server -- ls -la /usr/src/app/upload
# Should show photo library contents

kubectl exec -n entertainment deploy/kavita -- ls -la /books
# Should show book library contents

kubectl exec -n cloud deploy/nextcloud -- ls -la /var/www/html/data
# Should show Nextcloud user data directory
```

5. **Check Monitoring**:
```bash
# Grafana
kubectl port-forward -n observability svc/grafana 3000:3000

# Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
```

---

## 🔧 Post-Migration Configuration

### 1. Update Router Port Forwards

If needed, update router port forwards to point to new cluster IPs:
- Port 51413 (TCP/UDP) → Transmission peer port (LoadBalancer IP)
- Any exposed services via LoadBalancer

### 2. Update DNS Records

If using split-horizon DNS or external DNS records, update to point to new:
- `cluster_gateway_addr` (internal services)
- `cloudflare_gateway_addr` (external services)

### 3. Reconfigure Media Service UIs

If starting fresh (not restoring PVCs), reconfigure:

**Radarr** (`http://localhost:7878`):
- Settings → Media Management → Root Folders → `/media/Films`
- Settings → Download Clients → Transmission
  - Host: `transmission-app.downloads.svc.cluster.local`
  - Port: `9091`
- Settings → Indexers → Jackett
- Settings → Media Management → Importing → Set "Copy" mode

**Sonarr** (`http://localhost:8989`):
- Settings → Media Management → Root Folders → `/media/Series`
- Settings → Download Clients → Transmission
  - Host: `transmission-app.downloads.svc.cluster.local`
  - Port: `9091`
- Settings → Indexers → Jackett
- Settings → Media Management → Importing → Set "Copy" mode

**Seerr** (`http://localhost:5055`):
- Settings → Radarr → Add Server
  - Server Name: "Radarr"
  - Hostname/IP: `radarr.downloads.svc.cluster.local`
  - Port: `7878`
  - API Key: (from Radarr Settings → General → API Key)
- Settings → Sonarr → Add Server
  - Server Name: "Sonarr"
  - Hostname/IP: `sonarr.downloads.svc.cluster.local`
  - Port: `8989`
  - API Key: (from Sonarr Settings → General → API Key)

**Immich** (`http://localhost:2283`):
- First login will prompt to create admin account
- No additional configuration needed for basic photo management
- Library scanning happens automatically for `/usr/src/app/upload`

**Jellyfin** (`http://localhost:8096`):
- Initial setup wizard:
  - Add media libraries pointing to `/media/Films` and `/media/Series`
  - Select library types (Movies, TV Shows)
- No download client integration needed (Radarr/Sonarr handle that)

**Kavita** (`http://localhost:5000`):
- Initial setup: create admin account
- Add Library → Point to `/books`
- Scanner will index your ebook collection

**Home Assistant** (`http://localhost:8123`):
- Initial setup: create owner account
- Set up home location and timezone
- No database configuration needed (CNPG managed automatically)
- Integrations and automations can be added through UI

**Nextcloud** (`http://localhost`):
- Initial setup wizard will:
  - Create admin account (or use credentials from secret)
  - Detect PostgreSQL database automatically (CNPG managed)
  - Detect Dragonfly cache automatically (shared Redis-compatible instance)
- Data directory: `/var/www/html/data` (NFS-backed)
- Upload files, sync clients, configure users through web UI
- Apps can be installed from Nextcloud App Store

**Forgejo** (`http://localhost:3000`):
- Initial setup wizard will:
  - Create admin account (credentials from `forgejo-secret`)
  - Detect PostgreSQL database automatically (CNPG managed)
  - Configure domain and root URL (from HelmRelease)
- After initial setup:
  - Navigate to: Site Administration → Actions → Runners
  - Click: "New runner token"
  - Copy the token and add to `cluster.yaml`:
    ```yaml
    forgejo_runner_secret: "FGJ..."
    ```
  - Run: `task configure --yes`, commit, and push
  - Flux will reconcile and deploy the runners (2 replicas)
- Create repositories, push code, set up Actions workflows
- Built-in container registry: `forgejo.${SECRET_DOMAIN}/username/image:tag`

### 4. Restore Application Data (Optional)

If you want to preserve application state (Radarr/Sonarr libraries, etc.):

**Option A - NFS Backup/Restore**:
```bash
# On old cluster, backup config PVCs to NAS
kubectl exec -n downloads deploy/radarr -- tar czf /tmp/radarr-config.tar.gz /config
kubectl cp downloads/<radarr-pod>:/tmp/radarr-config.tar.gz ./radarr-config.tar.gz
# Copy to NAS

# Repeat for other services (sonarr, seerr if you want to keep its config)
kubectl exec -n downloads deploy/sonarr -- tar czf /tmp/sonarr-config.tar.gz /config
kubectl cp downloads/<sonarr-pod>:/tmp/sonarr-config.tar.gz ./sonarr-config.tar.gz

kubectl exec -n entertainment deploy/seerr -- tar czf /tmp/seerr-config.tar.gz /app/config
kubectl cp entertainment/<seerr-pod>:/tmp/seerr-config.tar.gz ./seerr-config.tar.gz

# On new cluster, restore
kubectl cp ./radarr-config.tar.gz downloads/<radarr-pod>:/tmp/
kubectl exec -n downloads deploy/radarr -- tar xzf /tmp/radarr-config.tar.gz -C /
kubectl delete pod -n downloads -l app.kubernetes.io/name=radarr  # Restart
```

**Option B - Velero Backup** (if installed):
```bash
# On old cluster
velero backup create pre-migration --include-namespaces downloads,entertainment,database-system

# On new cluster
velero restore create --from-backup pre-migration
```

---

## 📊 Performance Expectations

### Old Cluster (Raspberry Pi 4)
- Storage: ~55GB/node, limited by SD/SSD via USB
- RAM: Limited
- CPU: ARM Cortex-A72 (quad-core 1.5GHz)
- Network: Gigabit Ethernet

### New Cluster (ThinkCentre)
- Storage: 512GB SSD (native SATA/NVMe - much faster)
- RAM: 16GB (plenty for workloads)
- CPU: Core i5 3.2GHz (significantly more powerful)
- Expected improvements:
  - **Faster downloads**: More headroom for Transmission
  - **Faster media processing**: Radarr/Sonarr imports will be quicker
  - **Better database performance**: CNPG and Dragonfly will be snappier
  - **Entertainment services will deploy**: Immich, Jellyfin, and Kavita blocked by RPi resource constraints will work
  - **Immich ML performance**: Machine learning features (face detection, object recognition) will be much faster
  - **Room to grow**: Can add more services without resource constraints

---

## 🚨 Common Issues & Solutions

### Issue: Pods Stuck in Pending (PVC Mount Issues)
**Cause**: Longhorn not ready or volume attachment issues  
**Solution**:
```bash
# Check Longhorn status
kubectl get pods -n storage | grep longhorn

# Check PVC status
kubectl get pvc -A

# Describe pending pod
kubectl describe pod -n <namespace> <pod-name>
```

### Issue: Media Services Not on Correct Node
**Cause**: `media-node=true` label not applied  
**Solution**:
```bash
# Verify label
kubectl get nodes --show-labels | grep media-node

# Apply if missing
kubectl label node <node-name> media-node=true

# Restart pods to reschedule
kubectl delete pod -n downloads -l app.kubernetes.io/name=transmission
kubectl delete pod -n downloads -l app.kubernetes.io/name=radarr
kubectl delete pod -n downloads -l app.kubernetes.io/name=sonarr
```

### Issue: NFS Mounts Fail
**Cause**: NFS server unreachable or wrong IP  
**Solution**:
```bash
# Verify NFS server is accessible
ping 192.168.1.37

# Test NFS mount from a node
talosctl -n <node-ip> read /proc/mounts | grep nfs

# Check storage class
kubectl get storageclass nfs-media -o yaml

# Verify NFS CSI driver pods
kubectl get pods -n storage | grep nfs
```

### Issue: Garage Not Ready, Blocking CNPG
**Cause**: Stale HelmRelease status  
**Solution**:
```bash
# Suspend and resume
flux suspend helmrelease -n storage garage
flux resume helmrelease -n storage garage

# Force reconcile
flux reconcile kustomization -n storage garage
```

### Issue: Immich Server Can't Connect to Database
**Cause**: Database environment variables not properly nested in chart 0.11.1+  
**Solution**:
```bash
# Verify database is ready
kubectl get clusters.postgresql.cnpg.io -n entertainment immich-postgres

# Should show: Instances=1, Ready=1, Status=Cluster in healthy state

# Check database secret exists
kubectl get secret -n entertainment immich-postgres-app

# If server can't connect, verify env vars structure in helmrelease:
# Must be: server.controllers.main.containers.main.env (NOT at root level)
```

### Issue: Immich Machine Learning Pod Startup Probe Timeout
**Cause**: ML models take time to download on first start  
**Solution**: Already configured with extended timeouts:
```yaml
startupProbe:
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 30  # Allows up to 5 minutes for startup
```
Be patient on first deployment - ML models are ~2-4GB and need to download.

### Issue: NFS CSI Driver Creating `pvc-*` Subdirectories
**Cause**: Dynamic provisioning creates UUID-named subdirectories for each PVC  
**Solution**: Use static PersistentVolumes pointing directly to existing NAS paths
```bash
# Already configured in Git for all NFS-backed apps:
# - Radarr, Sonarr, Jellyfin → share static PV pointing to /videos
# - Immich → static PV pointing to /immich/library
# - Kavita → static PV pointing to /books

# After migration, clean up old pvc-* directories on NAS:
# rm -rf /mnt/nfs_share/videos/pvc-*
# rm -rf /mnt/nfs_share/immich/pvc-*
```
**Cause**: Resource exhaustion - Longhorn cannot attach volumes due to insufficient node resources  
**Solution**: This is expected on RPi cluster. These apps will work fine on ThinkCentre hardware with 16GB RAM and proper storage.
```bash
# Don't waste time troubleshooting on RPi - verify configs are correct:
kubectl get helmrelease -n entertainment
# All should show: Ready=True (even if pods aren't running)

# On ThinkCentre after migration, these will start normally
```

### Issue: Flux Can't Access Git Repository
**Cause**: SSH key or GitHub token issues  
**Solution**:
```bash
# Check Flux system status
flux check

# Verify Git repository
flux get sources git

# If needed, update GitHub credentials
kubectl edit secret -n flux-system flux-system
```

---

## 🔐 Important Files to Keep

### Keep Safe (Not in Git)
- `age.key` - SOPS encryption key (same key on new cluster)
- `kubeconfig` - Generated after bootstrap
- `talos/clusterconfig/talosconfig` - Generated after Talos bootstrap

### In Git Repository
- All `kubernetes/` manifests
- All `templates/` Jinja2 templates
- `cluster.yaml` - Cluster configuration
- `talos/talconfig.yaml` - Talos configuration
- `.sops.yaml` - SOPS configuration
- `Taskfile.yaml` - Task automation

---

## 🔐 Post-Deployment: Setup Authelia IAP (Optional but Recommended)

After your cluster is deployed, you can add Identity-Aware Proxy authentication to protect your external apps (Immich, Nextcloud, Kavita, Jellyfin) with centralized authentication and MFA.

### Why Add Authelia?

- **Security:** Kavita has NO built-in authentication and is publicly accessible ⚠️
- **MFA Protection:** TOTP (Google Authenticator/Authy) required for all external apps
- **Single Sign-On:** One login for all protected services
- **Location Independent:** Access from anywhere with proper credentials

### Setup Steps

1. **Generate Authelia credentials:**

```bash
# Generate password hash
docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'YourStrongPassword'
# Copy the output starting with $argon2id$v=19$...

# Generate secrets
openssl rand -hex 32  # session_secret
openssl rand -hex 32  # storage_encryption_key  
openssl rand -hex 32  # jwt_secret
```

2. **Add to your `cluster.yaml`:**

```yaml
# Authelia IAP configuration (add at end of file)
authelia_username: "admin"
authelia_displayname: "Your Name"
authelia_email: "your@jgrecu.dev"
authelia_password_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."  # from step 1
authelia_session_secret: "abc123..."  # from step 1
authelia_storage_encryption_key: "def456..."  # from step 1
authelia_jwt_secret: "ghi789..."  # from step 1
```

3. **Generate and deploy:**

```bash
cd /Users/I337469/Downloads/talos-rpi4/home-lab

# Generate kubernetes manifests
task configure --yes

# Verify generated files
ls -la kubernetes/apps/security/
ls -la kubernetes/apps/network/envoy-gateway/app/authelia-securitypolicy.yaml

# Commit and push
git add -A
git commit -m "feat: add Authelia IAP for external apps"
git push
```

4. **Monitor deployment:**

```bash
# Watch Flux reconcile (5-10 minutes)
flux get kustomizations --watch

# Check Authelia deployment
kubectl get pods -n security

# Verify SecurityPolicy applied
kubectl get securitypolicy -n network authelia-external-auth

# Test authentication
curl -I https://immich.jgrecu.dev
# Should return: HTTP/2 302 (redirect to auth.jgrecu.dev)
```

5. **First login and MFA setup:**

- Visit any protected app: `https://immich.jgrecu.dev`
- You'll be redirected to: `https://auth.jgrecu.dev`
- Login with your username and password
- Scan QR code with Google Authenticator/Authy/1Password
- Enter TOTP code
- You'll be redirected back to the app

### What Gets Protected

- ✅ **Immich** - Photo management (auth.jgrecu.dev → immich.jgrecu.dev)
- ✅ **Nextcloud** - Cloud storage (auth.jgrecu.dev → nextcloud.jgrecu.dev)
- ✅ **Kavita** - Ebook reader (auth.jgrecu.dev → kavita.jgrecu.dev)
- ✅ **Jellyfin** - Media streaming (auth.jgrecu.dev → jellyfin.jgrecu.dev)
- ✅ **Authelia** - Appears on Homepage dashboard under "Infrastructure"
- ⚠️ **Echo** - Bypassed (for testing/webhooks)

### Session Details

- **Session Duration:** 12 hours (absolute), 2 hours (inactivity)
- **Remember Me:** 1 month
- **Backup:** Volsync backs up Authelia database daily at 3:15 AM
- **Storage:** SQLite (1Gi PVC on Longhorn)

### Troubleshooting

**Authelia pod not starting:**
```bash
kubectl describe pod -n security -l app.kubernetes.io/name=authelia
kubectl logs -n security -l app.kubernetes.io/name=authelia
```

**Apps not redirecting to auth:**
```bash
# Verify SecurityPolicy is applied
kubectl get securitypolicy -n network authelia-external-auth -o yaml

# Check Envoy Gateway logs
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external
```

**Can't login (incorrect password):**
```bash
# Regenerate password hash
docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'NewPassword'

# Update cluster.yaml with new hash
# Run: task configure --yes
# Commit and push
```

---

## 🔐 Important Files to Keep (Continued)

### Keep Safe (Not in Git)
- `age.key` - SOPS encryption key (same key on new cluster)
- `kubeconfig` - Generated after bootstrap
- `talos/clusterconfig/talosconfig` - Generated after Talos bootstrap

### In Git Repository
- All `kubernetes/` manifests
- All `templates/` Jinja2 templates
- `cluster.yaml` - Cluster configuration
- `talos/talconfig.yaml` - Talos configuration
- `.sops.yaml` - SOPS configuration
- `Taskfile.yaml` - Task automation

---

## 📝 Pre-Migration Checklist

Before starting migration:

- [ ] Commit all current changes: `git push`
- [ ] Backup `age.key` file securely
- [ ] Backup `cluster.yaml` and `talos/talconfig.yaml`
- [ ] **Note**: Keep existing Garage S3 credentials from `cluster.yaml` if you want to reuse buckets, or plan to run `task storage:bootstrap-garage` to generate fresh credentials
- [ ] Document current IP addresses and network layout
- [ ] Note which applications are critical vs. nice-to-have
- [ ] Export/backup media service configurations (Radarr/Sonarr libraries)
- [ ] Verify NAS is accessible and `/videos/{Films,Series}` structure is correct
- [ ] Verify GitHub repository access and SSH keys
- [ ] Have new hardware MAC addresses ready
- [ ] Choose IP address range for new cluster
- [ ] Decide which worker gets `media-node=true` label

---

## 📚 Reference Commands

### Talos
```bash
# Generate configs
task talos:generate-config

# Apply config to node
talosctl apply-config --nodes <ip> --file <config.yaml>

# Bootstrap etcd
talosctl bootstrap --nodes <controller-ip>

# Get kubeconfig
talosctl --nodes <controller-ip> kubeconfig .

# Check health
talosctl --nodes <ip> health

# Watch services
talosctl --nodes <ip> services
```

### Flux
```bash
# Bootstrap Flux
task bootstrap:flux

# Check status
flux check
flux get all

# Reconcile
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization cluster-apps --with-source

# Suspend/Resume
flux suspend helmrelease -n <namespace> <name>
flux resume helmrelease -n <namespace> <name>
```

### Kubectl
```bash
# Get all resources
kubectl get all -A

# Check specific namespace
kubectl get pods -n <namespace> -o wide

# Describe for troubleshooting
kubectl describe pod -n <namespace> <pod-name>

# Logs
kubectl logs -n <namespace> <pod-name> --tail=50 -f

# Port forward
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<service-port>
```

---

## ✅ Success Criteria

Your migration is successful when:

1. [ ] All nodes show `Ready` status
2. [ ] Flux kustomizations all show `Applied` (check with `flux get kustomizations`)
3. [ ] Storage system healthy (Longhorn, Garage, NFS CSI, Volsync)
4. [ ] Media services running on designated `media-node`
5. [ ] Media services can access NFS mounts (`/media/Films`, `/media/Series`)
6. [ ] Transmission can download (test with a legal torrent)
7. [ ] Radarr/Sonarr can see downloads and move to NFS
8. [ ] **Entertainment services all running**: Seerr, Immich (with database), Jellyfin, Kavita
9. [ ] **Immich database operational**: PostgreSQL cluster healthy, server connected
10. [ ] **Immich ML features working**: Face detection, object recognition running
11. [ ] **Home Assistant running**: PostgreSQL cluster healthy, UI accessible
12. [ ] **Nextcloud running**: PostgreSQL cluster healthy, Redis connected, UI accessible
13. [ ] **Forgejo running**: PostgreSQL cluster healthy, UI accessible, container registry working
14. [ ] **Forgejo runners operational**: 2 replicas running (after token configured)
15. [ ] **Volsync backups configured**: ReplicationSources created for all services
16. [ ] Monitoring stack accessible (Grafana, Prometheus)
17. [ ] External access works (if using Cloudflare tunnel)
18. [ ] No pods stuck in `CrashLoopBackOff` or `Pending`

---

## 🎯 Quick Start (TL;DR)

```bash
# 1. Clean up and backup
git add -A && git commit -m "backup: RPi4 state" && git push
cp age.key ~/Desktop/age.key.backup.$(date +%Y%m%d)
task template:reset

# 2. Generate x86_64 schematic at factory.talos.dev
# - Version: v1.12.6, Arch: amd64, Platform: metal
# - Extensions: iscsi-tools, intel-ucode, i915-ucode
# - Copy schematic ID and download ISO

# 3. Boot ThinkCentre machines
# - Flash ISO to USB
# - Boot each machine (remove USB after boot, reuse for next)
# - nmap -Pn -n -p 50000 192.168.1.0/24 -vv | grep 'Discovered'

# 4. Collect hardware info
talosctl get disks -n 192.168.1.X --insecure
talosctl get links -n 192.168.1.X --insecure

# 5. Update configs
task init  # if starting fresh
vim nodes.yaml  # Update with new hardware details + schematic ID
vim cluster.yaml  # Review/update network IPs

# 6. Regenerate configs
task configure --yes

# 7. Commit
git add -A && git commit -m "feat: migrate to ThinkCentre x86_64" && git push

# 8. Bootstrap Talos (installs + bootstraps etcd + kubeconfig)
task bootstrap:talos

# 9. Commit encrypted secrets
git add -A && git commit -m "chore: add talhelper encrypted secret" && git push

# 10. Bootstrap apps (Cilium, CoreDNS, Spegel, Flux, all apps)
task bootstrap:apps

# 11. Bootstrap Garage S3 (CRITICAL - required before CNPG)
kubectl wait --for=condition=ready pod -n storage -l app.kubernetes.io/name=garage --timeout=300s
task storage:bootstrap-garage
git add cluster.yaml kubernetes/ bootstrap/ && git commit -m "chore: update Garage credentials" && git push
flux reconcile kustomization cluster-apps --with-source

# 12. Watch deployment
flux get kustomizations --watch
kubectl get pods -A

# 13. Verify
kubectl get nodes --show-labels | grep media-node
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

---

## 📞 Support Resources

- **Talos Documentation**: https://www.talos.dev/latest/
- **Flux Documentation**: https://fluxcd.io/docs/
- **Longhorn Documentation**: https://longhorn.io/docs/
- **Kubernetes Documentation**: https://kubernetes.io/docs/

---

**Migration prepared**: April 15, 2026  
**Source cluster**: Raspberry Pi 4 cluster (1 CP + 4 workers)  
**Target cluster**: ThinkCentre (1 CP + 2 workers, Core i5, 512GB SSD, 16GB RAM)

Good luck with the migration! 🚀
