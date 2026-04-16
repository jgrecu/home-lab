# Documentation

Documentation for the Talos Raspberry Pi 4 home lab cluster.

## Backup & Recovery

### Volsync Automated Backups

- **[Volsync Deployment Guide](./volsync-deployment-guide.md)** - Complete guide to deploying Volsync for automated PVC backups
- **[Volsync Restore Procedures](./volsync-restore-procedures.md)** - Step-by-step restore procedures for disaster recovery

## Quick Start

### Deploy Volsync Backups

```bash
# 1. Bootstrap Garage S3 (creates volsync-backups bucket)
task storage:bootstrap-garage

# 2. Add Volsync config to cluster.yaml
# Edit cluster.yaml and add volsync.restic_password

# 3. Regenerate manifests
task configure --yes

# 4. Commit and push
git add . && git commit -m "feat(volsync): add automated backups" && git push

# 5. Verify deployment
kubectl get replicationsource -A
```

### Restore from Backup

See [Volsync Restore Procedures](./volsync-restore-procedures.md) for detailed instructions.

Quick restore:
```bash
# 1. Scale down application
kubectl scale deployment <app> -n <namespace> --replicas=0

# 2. Create ReplicationDestination
# See restore guide for examples

# 3. Scale up application
kubectl scale deployment <app> -n <namespace> --replicas=1
```

## Architecture

### Storage Stack

```
Applications
    ↓
Longhorn (replicated block storage)
    ↓
┌─────────┴─────────┐
│                   │
Volsync          Direct Access
(backups)        (live data)
│
↓
Garage S3
```

### Backup Strategy

- **Longhorn**: Provides replica redundancy across nodes (3 replicas)
- **Volsync**: Automated daily backups to S3 (7 daily, 4 weekly, 3 monthly)
- **Garage**: S3-compatible object storage for backup target
- **NFS**: Static PVs for media files (backed up at NAS level)

### What Gets Backed Up

✅ **Critical PVCs** (automated with Volsync):
- Immich database
- Kavita config
- Homepage config
- Grafana database

❌ **Not backed up** (too large or already on NAS):
- Media files (Jellyfin, Immich photos)
- Temporary caches
- Longhorn replicas (already redundant)

## Recovery Objectives

- **RTO (Recovery Time Objective)**: 
  - Single PVC: 15-30 minutes
  - Full cluster: 4-6 hours

- **RPO (Recovery Point Objective)**:
  - Critical DBs: 24 hours (daily backups)
  - Config files: 24 hours (daily backups)

## Maintenance

### Monthly Tasks

- [ ] Test backup restore in `backup-test` namespace
- [ ] Verify all ReplicationSources have recent `lastSyncTime`
- [ ] Check S3 bucket usage and retention
- [ ] Review Volsync logs for errors

### Quarterly Tasks

- [ ] Practice disaster recovery procedure
- [ ] Update restore documentation if configs changed
- [ ] Review and adjust retention policies
- [ ] Validate backup health monitoring alerts

## Related Resources

- [Longhorn Documentation](https://longhorn.io/docs/)
- [Volsync Documentation](https://volsync.readthedocs.io/)
- [Restic Documentation](https://restic.readthedocs.io/)
- [Garage S3 Documentation](https://garagehq.deuxfleurs.fr/)
