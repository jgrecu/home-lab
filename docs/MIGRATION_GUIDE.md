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
  - Barman continuous WAL archiving (30-day retention)
- **Dragonfly**: Redis-compatible cache (v1.38.0)
  - Used by: Immich (job queues), Nextcloud (file locking/sessions)

#### Storage System
- **Longhorn**: Block storage with 2 replicas
- **Garage**: S3-compatible object storage for backups (already bootstrapped)
  - Buckets: `longhorn-backups`, `cnpg-backups`, `volsync-backups`
- **NFS CSI Driver**: For media library access
- **Volsync**: Automated PVC backups to Garage S3
  - Daily backups: Homepage (1 AM), Home Assistant (2 AM), Nextcloud (1 AM), Forgejo (3 AM)
  - Daily backups: Immich DB (3 AM), Kavita (3 AM), Grafana (4 AM)
  - Retention: 7 daily, 4 weekly, 3 monthly snapshots

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

### Phase 1: Prepare Configuration

1. **Backup Current Cluster State**:
```bash
cd /Users/I337469/Downloads/talos-rpi4/home-lab

# Backup current configs
cp talos/talconfig.yaml talos/talconfig.yaml.rpi-backup
cp cluster.yaml cluster.yaml.rpi-backup

# Commit current state
git add -A
git commit -m "backup: final RPI cluster state before migration"
git push
```

2. **Update Talos Configuration**:
```bash
# Edit for new hardware
vim talos/talconfig.yaml

# Update:
# - Node count (1 controller + 2 workers)
# - Hostnames (e.g., thinkcentre-ctrl, thinkcentre-wrk1, thinkcentre-wrk2)
# - IP addresses
# - MAC addresses (from new machines)
# - Add nodeLabels.media-node: "true" to one worker

# Validate
talhelper validate talconfig talos/talconfig.yaml
```

3. **Update Cluster Configuration**:
```bash
# Edit network IPs
vim cluster.yaml

# Update:
# - cluster_api_addr
# - cluster_dns_gateway_addr
# - cluster_gateway_addr
# - cloudflare_gateway_addr
# - pihole_dns_addr
# - nfs_server_addr (if NAS IP changed)

# Optional: Increase storage sizes
vim templates/config/kubernetes/apps/downloads/downloads-pvc.yaml.j2
vim templates/config/kubernetes/apps/database-system/dragonfly-instance/app/dragonfly.yaml.j2
```

4. **Regenerate All Configs**:
```bash
# Regenerate Kubernetes manifests
task configure --yes

# Regenerate Talos configs
task talos:generate-config

# Review changes
git diff

# Commit
git add -A
git commit -m "feat: migrate cluster config to ThinkCentre hardware"
git push
```

### Phase 2: Bootstrap New Cluster

1. **Install Talos on New Nodes**:
```bash
# Boot nodes from Talos ISO or via PXE
# Apply configurations (one at a time)

# Apply to controller first
talosctl apply-config --nodes <controller-ip> \
  --file ./talos/clusterconfig/thinkcentre-ctrl.yaml

# Wait for controller to be ready
talosctl --nodes <controller-ip> health

# Bootstrap etcd on controller
talosctl bootstrap --nodes <controller-ip>

# Apply to workers
talosctl apply-config --nodes <worker1-ip> \
  --file ./talos/clusterconfig/thinkcentre-wrk1.yaml

talosctl apply-config --nodes <worker2-ip> \
  --file ./talos/clusterconfig/thinkcentre-wrk2.yaml
```

2. **Get Kubeconfig**:
```bash
# Retrieve kubeconfig
talosctl --nodes <controller-ip> kubeconfig .

# Verify cluster access
kubectl get nodes
```

3. **Bootstrap Flux**:
```bash
# Install Flux (will deploy everything from Git)
task bootstrap:flux

# Monitor deployment
flux get kustomizations --watch

# Check pods across all namespaces
kubectl get pods -A
```

4. **Verify Storage**:
```bash
# Wait for Longhorn to be ready
kubectl get pods -n storage

# Check Garage is healthy
kubectl get helmrelease -n storage garage

# Verify NFS storage classes
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
# 2. Create buckets (longhorn-backups, cnpg-backups, etc.)
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

**Note**: The bootstrap task will update your `cluster.yaml` with new S3 credentials:
```yaml
garage_s3_access_key_id: "GK..."
garage_s3_secret_access_key: "..."
```

**Verify Garage is ready**:
```bash
# Check Garage HelmRelease status
kubectl get helmrelease -n storage garage

# Should show: Ready=True, Status="Helm upgrade succeeded"

# Check that CNPG can now proceed
kubectl get kustomization -n database-system cloudnative-pg

# Should show: Ready=True (no longer blocked by Garage dependency)
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
# 1. Update configs for new hardware
vim talos/talconfig.yaml    # Update nodes, add media-node label
vim cluster.yaml             # Update IPs

# 2. Regenerate everything
task configure --yes
task talos:generate-config

# 3. Commit
git add -A && git commit -m "feat: migrate to ThinkCentre" && git push

# 4. Install Talos on new nodes
talosctl apply-config --nodes <ctrl-ip> --file ./talos/clusterconfig/ctrl.yaml
talosctl bootstrap --nodes <ctrl-ip>
talosctl apply-config --nodes <wrk1-ip> --file ./talos/clusterconfig/wrk1.yaml
talosctl apply-config --nodes <wrk2-ip> --file ./talos/clusterconfig/wrk2.yaml

# 5. Get kubeconfig
talosctl --nodes <ctrl-ip> kubeconfig .

# 6. Bootstrap Flux (deploys everything)
task bootstrap:flux

# 7. Bootstrap Garage S3 storage (CRITICAL - required before CNPG can start)
kubectl wait --for=condition=ready pod -n storage -l app.kubernetes.io/name=garage --timeout=300s
task storage:bootstrap-garage
git add cluster.yaml kubernetes/ bootstrap/ && git commit -m "chore: update Garage credentials" && git push
flux reconcile kustomization cluster-apps --with-source

# 8. Watch deployment
flux get kustomizations --watch

# 8. Verify
kubectl get pods -A
kubectl get nodes --show-labels | grep media-node
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
