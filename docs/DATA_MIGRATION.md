# Data Migration Guide: RPi5 → Kubernetes Cluster

This guide covers migrating existing service data from a standalone RPi5 setup to the Kubernetes cluster.

## Source Environment
- **Host**: jeremy@mediagw (RPi5 with SSD)
- **Data Location**: `/share/`
- **Services**: Docker containers with bind mounts

## Target Environment
- **Cluster**: Talos Kubernetes (3 nodes)
- **Storage**: Longhorn (block) + NFS (media)
- **Namespaces**: downloads, entertainment, cloud, forgejo, home-automation

## Pre-Migration Checklist

- [ ] Ensure cluster is healthy and all services are deployed
- [ ] Verify NFS mounts are accessible from cluster nodes
- [ ] Take snapshots of source data on RPi5
- [ ] Note down any service-specific credentials or API keys
- [ ] Check current service versions match between source and target

## Migration Strategies

### Strategy A: NFS Direct Copy (Media Libraries)

**Use for**: Large read-only or append-only data that doesn't change often.

**Services**: Radarr, Sonarr, Jellyfin, Kavita, Immich

**Target NFS Paths**:
- `/videos/Films` → Radarr movies
- `/videos/Series` → Sonarr TV shows  
- `/videos/` → Jellyfin library (reads both Films and Series)
- `/books` → Kavita ebooks/manga
- `/immich/library` → Immich photos/videos

**Steps**:
```bash
# From your workstation or directly on NAS
# Replace YOUR_NAS with actual NAS hostname/IP

# Radarr movies
rsync -avP --delete jeremy@mediagw:/share/radarr/ YOUR_NAS:/videos/Films/

# Sonarr TV shows
rsync -avP --delete jeremy@mediagw:/share/sonarr/ YOUR_NAS:/videos/Series/

# Kavita books
rsync -avP --delete jeremy@mediagw:/share/kavita/ YOUR_NAS:/books/

# Jellyfin (if it has separate content not in radarr/sonarr)
rsync -avP --delete jeremy@mediagw:/share/jellyfin/ YOUR_NAS:/videos/

# Immich photos (if you have existing library)
rsync -avP --delete jeremy@mediagw:/share/immich/ YOUR_NAS:/immich/library/
```

**Verification**:
```bash
# From a cluster node or pod with NFS mount
ls -lh /path/to/nfs/mount
```

### Strategy B: PVC Restoration (Application Config/State)

**Use for**: Application configuration, caches, small databases.

**Services**: Jackett, Transmission, Seerr, Jellyfin (config), Home Assistant (config)

**PVC Mapping**:
| Service | Source Path | PVC Name | Mount Path | Size |
|---------|-------------|----------|------------|------|
| Jackett | `/share/jackett` | `jackett-config` | `/config` | 2Gi |
| Transmission | `/share/transmission` | `transmission-config` | `/config` | 1Gi |
| Seerr | `/share/seerr` | `seerr-config` | `/app/config` | 2Gi |
| Jellyfin | `/share/jellyfin` | `jellyfin-config` | `/config` | 10Gi |
| Home Assistant | `/share/home-assistant` | `home-assistant-config` | `/config` | 5Gi |
| Nextcloud | `/share/nextcloud-data` | NFS PVC | `/var/www/html` | 1Ti |

#### Step 1: Create Backup Tarballs on RPi5
```bash
# SSH to RPi5
ssh jeremy@mediagw

cd /share

# Create backups (exclude cache/temp directories)
tar czf /tmp/jackett-backup.tar.gz \
  --exclude='jackett/logs' \
  --exclude='jackett/Jackett/logs' \
  jackett/

tar czf /tmp/transmission-backup.tar.gz \
  --exclude='transmission/torrents' \
  --exclude='transmission/log' \
  transmission/

tar czf /tmp/seerr-backup.tar.gz \
  --exclude='seerr/logs' \
  --exclude='seerr/cache' \
  seerr/

tar czf /tmp/jellyfin-backup.tar.gz \
  --exclude='jellyfin/transcodes' \
  --exclude='jellyfin/log' \
  jellyfin/

tar czf /tmp/home-assistant-backup.tar.gz home-assistant/

tar czf /tmp/nextcloud-backup.tar.gz nextcloud-data/

# List backup sizes
ls -lh /tmp/*-backup.tar.gz
```

#### Step 2: Transfer Backups to Cluster
```bash
# From your workstation
# Copy from RPi5 to local machine
scp jeremy@mediagw:/tmp/*-backup.tar.gz /tmp/

# Copy to cluster controller node
scp /tmp/*-backup.tar.gz root@192.168.1.50:/var/tmp/
```

#### Step 3: Restore into PVCs

**Generic Restoration Script** (customize per service):

```bash
#!/bin/bash
# restore-pvc.sh - Generic PVC restoration script
# Usage: ./restore-pvc.sh <namespace> <service-name> <pvc-name> <backup-file> <mount-path>

NAMESPACE=$1
SERVICE=$2
PVC_NAME=$3
BACKUP_FILE=$4
MOUNT_PATH=$5

echo "==> Restoring $SERVICE in namespace $NAMESPACE"

# Wait for service to be ready first
echo "Waiting for $SERVICE to deploy..."
kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=$SERVICE -n $NAMESPACE --timeout=300s || {
  echo "Warning: Deployment not ready, but proceeding anyway"
}

# Scale down the deployment
echo "Scaling down $SERVICE..."
kubectl scale deployment -l app.kubernetes.io/name=$SERVICE -n $NAMESPACE --replicas=0

# Wait for pods to terminate
kubectl wait --for=delete pod -l app.kubernetes.io/name=$SERVICE -n $NAMESPACE --timeout=60s 2>/dev/null || true

# Create restore pod
echo "Creating restore pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-$SERVICE
  namespace: $NAMESPACE
spec:
  containers:
  - name: restore
    image: alpine:latest
    command: ["sleep", "7200"]
    volumeMounts:
    - name: data
      mountPath: $MOUNT_PATH
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVC_NAME
  restartPolicy: Never
EOF

# Wait for restore pod
echo "Waiting for restore pod..."
kubectl wait --for=condition=ready pod/restore-$SERVICE -n $NAMESPACE --timeout=120s

# Copy backup into pod
echo "Copying backup into pod..."
kubectl cp /var/tmp/$BACKUP_FILE $NAMESPACE/restore-$SERVICE:/tmp/backup.tar.gz

# Extract backup
echo "Extracting backup into PVC..."
kubectl exec -n $NAMESPACE restore-$SERVICE -- sh -c "
  apk add --no-cache tar
  cd $MOUNT_PATH
  tar xzf /tmp/backup.tar.gz --strip-components=1
  rm /tmp/backup.tar.gz
"

# Clean up restore pod
echo "Cleaning up restore pod..."
kubectl delete pod -n $NAMESPACE restore-$SERVICE

# Scale up the deployment
echo "Scaling up $SERVICE..."
kubectl scale deployment -l app.kubernetes.io/name=$SERVICE -n $NAMESPACE --replicas=1

echo "==> Restoration of $SERVICE complete!"
echo "    Verify service is working: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=$SERVICE -f"
```

**Service-Specific Restoration Commands**:

```bash
# Make script executable
chmod +x restore-pvc.sh

# Jackett
./restore-pvc.sh downloads jackett jackett-config jackett-backup.tar.gz /config

# Transmission
./restore-pvc.sh downloads transmission transmission-config transmission-backup.tar.gz /config

# Seerr
./restore-pvc.sh entertainment seerr seerr-config seerr-backup.tar.gz /app/config

# Jellyfin (config only, media is on NFS)
./restore-pvc.sh entertainment jellyfin jellyfin-config jellyfin-backup.tar.gz /config

# Home Assistant
./restore-pvc.sh home-automation home-assistant home-assistant-config home-assistant-backup.tar.gz /config

# Nextcloud (data directory to NFS)
# Note: This one uses NFS PVC, may need different approach
./restore-pvc.sh cloud nextcloud nextcloud-data nextcloud-backup.tar.gz /var/www/html
```

### Strategy C: PostgreSQL Database Migration

**Use for**: Services migrating from standalone PostgreSQL/MariaDB to CNPG.

**Services**: Forgejo, Nextcloud (if using external DB), Home Assistant (if using external DB)

#### Forgejo Database Migration

**Source**: PostgreSQL in Docker (`forgejo-db`)

```bash
# On RPi5, dump the database
ssh jeremy@mediagw
docker exec forgejo-db pg_dump -U forgejo -d forgejo -F c -f /tmp/forgejo.dump

# Copy to workstation
scp jeremy@mediagw:/tmp/forgejo.dump /tmp/

# Copy to cluster node
scp /tmp/forgejo.dump root@192.168.1.50:/var/tmp/

# From cluster, restore to CNPG
# Wait for CNPG cluster to be ready
kubectl wait --for=condition=ready cluster/forgejo-postgres -n forgejo --timeout=300s

# Get the primary pod
PRIMARY_POD=$(kubectl get pod -n forgejo -l cnpg.io/cluster=forgejo-postgres,role=primary -o jsonpath='{.items[0].metadata.name}')

# Copy dump to pod
kubectl cp /var/tmp/forgejo.dump forgejo/$PRIMARY_POD:/tmp/forgejo.dump

# Restore database
kubectl exec -n forgejo $PRIMARY_POD -- pg_restore -U forgejo -d forgejo -c /tmp/forgejo.dump

# Verify
kubectl exec -n forgejo $PRIMARY_POD -- psql -U forgejo -d forgejo -c '\dt'
```

#### Nextcloud Database Migration

**Note**: Check if your RPi5 Nextcloud uses PostgreSQL or MariaDB.

For PostgreSQL:
```bash
# Dump from RPi5
ssh jeremy@mediagw
docker exec nextcloud-db pg_dump -U nextcloud -d nextcloud -F c -f /tmp/nextcloud.dump

# Transfer and restore (similar to Forgejo above)
# Target: nextcloud-postgres cluster in cloud namespace
```

For MariaDB:
```bash
# Dump from RPi5
ssh jeremy@mediagw
docker exec nextcloud-db mysqldump -u nextcloud -p nextcloud > /tmp/nextcloud.sql

# Convert to PostgreSQL using pgloader (complex, see Nextcloud docs)
# OR: Use Nextcloud's export/import feature instead
```

#### Home Assistant Database Migration

**Note**: Home Assistant typically uses SQLite by default.

**Option 1**: Migrate SQLite to PostgreSQL
```bash
# This is complex. Consider using a tool or starting fresh.
# See: https://www.home-assistant.io/integrations/recorder/
```

**Option 2**: Start fresh (recommended if history isn't critical)
```bash
# Just restore configuration.yaml and automations/scripts
# Let Home Assistant create new PostgreSQL schema
# Historical data will be lost but config is preserved
```

### Strategy D: Fresh Start + Manual Reconfiguration

**Use for**: Services where config is simple or data export/import is easier than migration.

**Candidates**: 
- Home Assistant (if not using external DB)
- Bazarr (not configured yet in cluster)
- Nginx Proxy Manager (replaced by Envoy Gateway in cluster)

**Steps**:
1. Let service deploy fresh
2. Access UI and reconfigure manually
3. If service has export/import feature, use that instead of file copy

## Migration Order (Recommended)

### Phase 1: Media Libraries (Low Risk)
1. [ ] Copy media files to NFS (Radarr, Sonarr, Jellyfin, Kavita)
2. [ ] Verify NFS mounts in cluster show correct data
3. [ ] Test Jellyfin playback from cluster deployment

### Phase 2: Download Stack Config (Medium Risk)
1. [ ] Restore Jackett config (indexers, API keys)
2. [ ] Restore Transmission config (download settings)
3. [ ] Restore Radarr config (quality profiles, indexer connections)
4. [ ] Restore Sonarr config (quality profiles, indexer connections)
5. [ ] Verify download stack integration (Jackett → Radarr/Sonarr → Transmission)

### Phase 3: Entertainment Services (Medium Risk)
1. [ ] Restore Seerr config (user requests, integration with Radarr/Sonarr)
2. [ ] Restore Jellyfin config (libraries, user accounts, viewing history)
3. [ ] Restore Kavita config (libraries, user accounts)
4. [ ] Start Immich fresh (or restore if you have existing photos)

### Phase 4: Databases (High Risk)
1. [ ] Migrate Forgejo database
2. [ ] Restore Forgejo data PVC (repos, LFS)
3. [ ] Migrate Nextcloud database (if applicable)
4. [ ] Restore Nextcloud data to NFS

### Phase 5: Home Automation (Medium Risk)
1. [ ] Restore Home Assistant config directory
2. [ ] Reconfigure database connection if needed
3. [ ] Test automations and integrations

## Post-Migration Verification

### Service Health Checks
```bash
# Check all pods are running
kubectl get pods --all-namespaces

# Check PVCs are bound
kubectl get pvc --all-namespaces

# Check HTTPRoutes are working
kubectl get httproute --all-namespaces

# Test Homepage autodiscovery
kubectl port-forward -n default svc/homepage 3000:3000
# Visit http://localhost:3000
```

### Service-Specific Verification

**Radarr/Sonarr**:
- [ ] Root folders point to correct NFS paths
- [ ] Download client (Transmission) is connected
- [ ] Indexers (Jackett) are responding
- [ ] Test a manual search

**Transmission**:
- [ ] Download directory is correct
- [ ] Port forwarding is configured (if needed)
- [ ] Speed limits and scheduling are preserved

**Jellyfin**:
- [ ] Libraries are scanning correctly
- [ ] User accounts and permissions work
- [ ] Playback works (test transcoding)
- [ ] HTTPS access via Gateway works

**Forgejo**:
- [ ] Repositories are accessible
- [ ] Git push/pull works
- [ ] Actions runners are registered
- [ ] Container registry is functional

**Nextcloud**:
- [ ] Files are accessible
- [ ] Sync clients can connect
- [ ] Apps and integrations work
- [ ] Background jobs are running

**Home Assistant**:
- [ ] Entities are discovered
- [ ] Automations trigger correctly
- [ ] Integrations connect
- [ ] Recorder database is writing

## Rollback Plan

If migration fails or services are unstable:

1. **Keep RPi5 running** until cluster is verified stable
2. **Point DNS back to RPi5** if needed (for external services)
3. **Have database dumps** saved externally before migration
4. **Document any manual configuration changes** made during migration

## Troubleshooting

### PVC Restore Issues
```bash
# If PVC is stuck or won't mount:
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Check Longhorn volume status
kubectl get volumes -n longhorn-system
```

### Permission Issues
```bash
# If service can't write to PVC after restore:
# Check UID/GID in HelmRelease (LinuxServer images use PUID/PGID)
# May need to chown files in the PVC:

kubectl exec -n <namespace> <pod-name> -- chown -R 1000:1000 /config
```

### Database Connection Issues
```bash
# If service can't connect to CNPG database:
# Check secret exists and has correct credentials:
kubectl get secret -n <namespace> <app>-postgres-app -o yaml

# Test connection from a debug pod:
kubectl run -n <namespace> test-db --image=postgres:16 --rm -it -- \
  psql -h <app>-postgres-rw -U <app> -d <app>
```

## Notes

- **Downtime**: Plan for 2-4 hours depending on data size
- **Bandwidth**: Large NFS copies may saturate network
- **Testing**: Test each service thoroughly before moving to next phase
- **Backups**: Keep RPi5 backups for at least 1 week after migration
- **DNS**: Update DNS records to point to new cluster after verification
