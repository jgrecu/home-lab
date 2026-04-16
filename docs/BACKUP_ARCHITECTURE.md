# Backup Architecture

This document explains the three-tier backup system and how storage is efficiently managed to prevent waste.

## Overview

The cluster uses **three complementary backup systems**, all storing to **Garage S3** on your NAS:

```
┌─────────────────────────────────────────────────────────────┐
│                    Garage S3 on NAS                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   volsync-   │  │    cnpg-     │  │  longhorn-   │      │
│  │   backups    │  │   backups    │  │   backups    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
         ▲                   ▲                   ▲
         │                   │                   │
    ┌────┴────┐         ┌────┴────┐        ┌────┴────┐
    │ Volsync │         │  CNPG   │        │Longhorn │
    └─────────┘         └─────────┘        └─────────┘
```

## Backup Systems

### 1. Volsync (Application PVC Backups)

**What it backs up**: Application configuration and state stored in Longhorn PVCs
- Homepage config (1Gi)
- Home Assistant config (5Gi)
- Nextcloud installation (10Gi)
- Forgejo data/repos (20Gi)
- Immich database PVC (10Gi)
- Kavita config (2Gi)
- Grafana dashboards (1Gi)

**Technology**: Restic with content-defined chunking
- **Deduplication**: Yes - only changed file chunks are stored
- **Compression**: Yes - built into Restic
- **Incremental**: Yes - only delta changes after initial backup

**Schedule**: Daily (various times to spread load)

**Retention Policy** (Updated):
```yaml
retain:
  daily: 7      # Last week (7 snapshots)
  weekly: 8     # Last 2 months (8 snapshots)
  monthly: 6    # Last 6 months (6 snapshots)
```

**Total snapshots**: ~21 snapshots per service
**Actual storage**: Much less due to deduplication - typically 2-3x the source size for 6 months

**Target**: `s3://volsync-backups/` in Garage

### 2. CloudNative-PG (PostgreSQL Databases)

**What it backs up**: PostgreSQL databases
- Immich database (photos metadata, ML vectors)
- Nextcloud database (files metadata, users, shares)
- Forgejo database (repos metadata, issues, PRs)

**Technology**: Barman with PostgreSQL WAL (Write-Ahead Log) streaming
- **Incremental**: Yes - continuous WAL archiving + periodic base backups
- **Point-in-time recovery**: Yes - can restore to any second within retention
- **Compression**: Yes - gzip on WAL files

**Schedule**: 
- WAL archiving: Continuous (as transactions occur)
- Base backups: Automatic (CNPG manages schedule)

**Retention Policy** (Updated):
```yaml
retentionPolicy: "180d"  # 6 months
```

**Storage efficiency**: 
- Base backup: Full database copy (compressed)
- WAL archives: Only transaction logs (very small)
- Old WAL segments deleted after retention period
- Typical storage: 1.5-2x database size for 6 months

**Target**: `s3://cnpg-backups/<app>-postgres/` in Garage

### 3. Longhorn (Block Storage Snapshots)

**What it backs up**: Longhorn volume snapshots (triggered by Volsync)
- Volsync creates Longhorn snapshots before reading PVCs
- These snapshots are then sent to Longhorn's S3 backup target

**Technology**: Block-level CoW (Copy-on-Write) snapshots
- **Incremental**: Yes - only changed blocks
- **Compression**: Configurable
- **Deduplication**: At block level

**Schedule**: Triggered by Volsync backup jobs (not independent)

**Retention**: Controlled by Volsync retention policy (snapshots are deleted after backup)

**Target**: `s3://longhorn-backups/` in Garage

**Note**: Longhorn backup target is primarily used for:
1. Disaster recovery (full volume restore)
2. Cross-cluster migration
3. Snapshot offloading from cluster storage

## Storage Efficiency

### Deduplication Explained

All three systems use intelligent deduplication:

**Restic (Volsync)**:
- Files split into variable-length chunks based on content
- Each unique chunk stored only once
- Multiple backups share common chunks
- Example: 10 daily backups of a 10GB PVC might only use 12-15GB total

**Barman (CNPG)**:
- Base backup: Full database dump (compressed)
- WAL files: Only changed data since last checkpoint
- Example: 100MB database with 1GB of transactions over 6 months might use 1.2GB total

**Longhorn**:
- Block-level snapshots track changed 4KB blocks
- Unchanged blocks reference original data
- Only modified blocks consume additional space

### Real-World Storage Estimates

For a typical home lab setup:

| Service | Source Size | 6-Month Backup Size | Ratio |
|---------|-------------|---------------------|-------|
| Homepage | 1 GB | ~2 GB | 2x |
| Home Assistant | 5 GB | ~10 GB | 2x |
| Nextcloud config | 10 GB | ~18 GB | 1.8x |
| Forgejo repos | 20 GB | ~35 GB | 1.75x |
| Immich DB | 10 GB | ~18 GB | 1.8x |
| Kavita config | 2 GB | ~4 GB | 2x |
| Grafana | 1 GB | ~2 GB | 2x |
| **Total** | **49 GB** | **~89 GB** | **1.8x** |

**CNPG databases** (additional):
- Immich: 8 GB → ~14 GB (1.75x)
- Nextcloud: 5 GB → ~9 GB (1.8x)
- Forgejo: 2 GB → ~4 GB (2x)
- **Total**: **15 GB** → **~27 GB** (1.8x)

**Grand total**: ~116 GB for 6 months of backups (vs ~980 GB if storing 21 full copies per service)

**Savings**: ~88% reduction through deduplication and incremental backups

## Retention Policy Rationale

**6 months (180 days)** provides:
- ✅ Recovery from accidental deletions (caught within days/weeks)
- ✅ Recovery from gradual corruption (caught within months)
- ✅ Historical snapshots for compliance/audit
- ✅ Enough history to track data growth trends
- ✅ Balance between protection and storage cost

**Tiered retention** (7 daily + 8 weekly + 6 monthly):
- Recent backups (7 days): High granularity for quick recovery
- Medium-term (2 months): Weekly is sufficient for most issues
- Long-term (6 months): Monthly for major incidents or compliance

## Backup Testing

### Verify Backups Are Running

```bash
# Check Volsync ReplicationSource status
kubectl get replicationsource -A

# Check CNPG backup status
kubectl get backup -n entertainment -l cnpg.io/cluster=immich-postgres
kubectl get backup -n cloud -l cnpg.io/cluster=nextcloud-postgres
kubectl get backup -n forgejo -l cnpg.io/cluster=forgejo-postgres

# Check Longhorn backups (via UI)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Visit http://localhost:8080
```

### List Backups in Garage

```bash
# Port-forward to Garage
kubectl port-forward -n storage svc/garage-s3 3900:3900

# Use AWS CLI with Garage endpoint
export AWS_ACCESS_KEY_ID="<your-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret>"
export AWS_ENDPOINT_URL="http://localhost:3900"

# List Volsync backups
aws s3 ls s3://volsync-backups/ --recursive --endpoint-url $AWS_ENDPOINT_URL

# List CNPG backups
aws s3 ls s3://cnpg-backups/ --recursive --endpoint-url $AWS_ENDPOINT_URL

# List Longhorn backups
aws s3 ls s3://longhorn-backups/ --recursive --endpoint-url $AWS_ENDPOINT_URL
```

### Test Restore (Example: Homepage)

```bash
# Scale down Homepage
kubectl scale deployment -n default homepage --replicas=0

# Create ReplicationDestination (Volsync restore)
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: homepage-restore
  namespace: default
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: homepage-config-restic-secret
    destinationPVC: homepage-restored
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: 1Gi
    copyMethod: Direct
EOF

# Wait for restore to complete
kubectl wait --for=condition=complete replicationdestination/homepage-restore -n default --timeout=300s

# Verify restored data
kubectl run -n default test-restore --image=alpine --rm -it --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test","image":"alpine","command":["sh"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"homepage-restored"}}]}}' \
  -- ls -la /data

# If satisfied, replace original PVC
kubectl delete pvc -n default homepage
kubectl patch pvc -n default homepage-restored -p '{"metadata":{"name":"homepage"}}'

# Scale back up
kubectl scale deployment -n default homepage --replicas=1
```

## Monitoring and Alerts

### Backup Job Failures

Volsync and CNPG surface backup failures as Kubernetes events:

```bash
# Check Volsync events
kubectl get events -n entertainment --field-selector involvedObject.kind=ReplicationSource

# Check CNPG events
kubectl get events -n entertainment --field-selector involvedObject.kind=Backup
```

### Storage Usage

Monitor Garage bucket sizes:

```bash
# From Garage pod
kubectl exec -n storage garage-0 -- garage bucket info volsync-backups
kubectl exec -n storage garage-0 -- garage bucket info cnpg-backups
kubectl exec -n storage garage-0 -- garage bucket info longhorn-backups
```

### Recommended Alerts

Set up alerts for:
- ⚠️ Volsync backup job failures (any ReplicationSource)
- ⚠️ CNPG backup failures (any Cluster)
- ⚠️ Garage disk usage >80%
- ⚠️ Backup age >48 hours (stale backups)

## Disaster Recovery Scenarios

### Scenario 1: Single PVC Corruption
**Example**: Homepage config corrupted

**Recovery**:
1. Use Volsync ReplicationDestination (see test restore above)
2. Restore to new PVC
3. Swap PVCs and restart pod
4. **RTO**: ~10 minutes
5. **RPO**: Last daily backup (max 24 hours data loss)

### Scenario 2: Database Corruption
**Example**: Immich database corrupted

**Recovery**:
```bash
# List available backups
kubectl exec -n entertainment immich-postgres-1 -- barman list-backup postgres

# Restore to specific backup
kubectl exec -n entertainment immich-postgres-1 -- barman recover postgres <backup-id> /var/lib/postgresql/data --remote-ssh-command "ssh postgres@immich-postgres-1"
```
**RTO**: ~30 minutes
**RPO**: Last WAL archive (typically <5 minutes data loss)

### Scenario 3: Complete Cluster Loss
**Example**: All nodes destroyed

**Recovery**:
1. Build new cluster (same node IPs, same Garage connection)
2. Deploy Flux + apps
3. Restore all PVCs via Volsync ReplicationDestination
4. CNPG will automatically restore databases from Garage
5. **RTO**: ~4 hours
6. **RPO**: Last daily backup for PVCs, last WAL for databases

### Scenario 4: Garage/NAS Loss
**Example**: NAS dies, Garage data lost

**Recovery**:
- ⚠️ **No backup of backups** - Garage data is not backed up elsewhere
- Recommendation: Use NAS RAID + NAS-level snapshots for Garage data directory
- Alternative: Configure secondary S3 target (e.g., Backblaze B2) for critical data

## Cost Analysis

### Storage Costs (NAS-based)

Assuming 1TB NAS with:
- Media: 600 GB (videos, photos, books)
- Longhorn data: 150 GB (replicas on cluster nodes, not NAS)
- Garage backups: 116 GB (calculated above)
- Free space: 134 GB

**NAS utilization**: 71.6% (healthy)

### Network Costs

Backups run at night (low activity):
- Volsync: ~10-30 minutes per job (depending on PVC size and changes)
- CNPG: Continuous WAL streaming (minimal bandwidth)
- Longhorn: Triggered by Volsync (no separate network hit)

**Total nightly bandwidth**: ~20-50 GB uploaded to NAS (on fast nights with many changes)

### Compute Costs

Backup pods are resource-light:
- Volsync mover: 50-100m CPU, 256-512Mi RAM
- CNPG Barman: Handled by PostgreSQL pods (no extra resources)
- Longhorn: Minimal overhead

**Total backup overhead**: <500m CPU, <2Gi RAM during backup windows

## Maintenance

### Prune Old Backups Manually (if needed)

Normally automatic, but to force prune:

```bash
# Force Volsync prune (triggers on next backup)
kubectl annotate replicationsource -n default homepage-config-backup \
  volsync.backube/force-prune="$(date +%s)"

# Force CNPG prune (happens automatically based on retentionPolicy)
# No manual action needed - CNPG manages this

# Force Longhorn prune
# Use Longhorn UI: Backup -> Select backup -> Delete
```

### Update Retention Policy

Already done! But for future reference:

1. Edit `templates/config/kubernetes/apps/*/backup/replicationsource.yaml.j2` (Volsync)
2. Edit `templates/config/kubernetes/apps/*/app/postgres.yaml.j2` (CNPG)
3. Run `task configure --yes`
4. Commit and push
5. Flux reconciles automatically
6. Next backup cycle applies new retention

## Summary

✅ **Three backup layers** for defense in depth
✅ **Intelligent deduplication** prevents storage waste  
✅ **6-month retention** balances protection and cost
✅ **~1.8x storage multiplier** (not 21x!) due to incremental/dedupe
✅ **Automated daily backups** with no manual intervention
✅ **Point-in-time recovery** for databases (CNPG WAL)
✅ **Tested restore procedures** documented above

Your NAS will use approximately **116 GB for 6 months** of backups covering **64 GB of source data** - a very efficient setup! 🎉
