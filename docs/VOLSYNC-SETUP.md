# Volsync Implementation Summary

## ✅ Complete - All Components Created

This document summarizes the Volsync backup solution implemented for the Talos RPi4 home lab.

## Architecture Decision

**Selected Stack**: Longhorn + Volsync + Garage S3

### Why Longhorn over OpenEBS?
- ✅ Lighter resource footprint (critical for RPi4)
- ✅ Better Talos Linux integration
- ✅ Built-in UI and snapshot management
- ✅ Simpler architecture, easier to maintain
- ✅ Already deployed and working

### Why Volsync?
- ✅ Application-consistent backups via Longhorn snapshots
- ✅ Automated scheduled backups to S3
- ✅ Point-in-time recovery
- ✅ Disaster recovery to new cluster
- ✅ Native Kubernetes CRDs (GitOps-friendly)
- ✅ Encrypted backups with Restic

## What Was Created

### 1. Core Volsync Deployment (5 files)
```
templates/config/kubernetes/apps/storage/volsync/
├── namespace.yaml.j2
├── ks.yaml.j2
└── app/
    ├── helmrepository.yaml.j2
    ├── helmrelease.yaml.j2
    └── kustomization.yaml.j2
```

### 2. Backup Configurations for 4 Critical Apps (16 files)

Each app has:
- Restic secret (SOPS-encrypted S3 credentials)
- ReplicationSource (backup schedule and retention)
- Kustomization
- Flux Kustomization

**Apps configured:**
- Immich database (`entertainment/immich/backup/`)
- Kavita config (`entertainment/kavita/backup/`)
- Homepage config (`default/homepage/backup/`)
- Grafana database (`observability/grafana/backup/`)

### 3. Documentation (3 files)
- `docs/volsync-deployment-guide.md` - Step-by-step deployment
- `docs/volsync-restore-procedures.md` - Complete restore procedures
- `docs/README.md` - Documentation index

### 4. Garage Integration
- Modified `scripts/bootstrap-garage.sh` to create `volsync-backups` bucket

## Backup Configuration

| Application | PVC | Schedule | Retention | Size |
|-------------|-----|----------|-----------|------|
| Immich DB | `immich-db` | 2:30 AM | 7d/4w/3m | 10Gi |
| Kavita | `kavita-config` | 3:00 AM | 7d/4w/3m | 2Gi |
| Homepage | `homepage` | 3:15 AM | 7d/4w/3m | 1Gi |
| Grafana | `grafana` | 3:30 AM | 7d/4w/3m | 5Gi |

**RPO (Recovery Point Objective)**: 24 hours (daily backups)
**RTO (Recovery Time Objective)**: 15-30 minutes per PVC

## Deployment Instructions

### Prerequisites
1. Talos cluster running
2. Longhorn deployed
3. Garage S3 deployed
4. Flux GitOps configured

### Step-by-Step

```bash
# 1. Bootstrap Garage (creates volsync-backups bucket)
task storage:bootstrap-garage

# 2. Generate Restic password and add to cluster.yaml
openssl rand -base64 32

# Edit cluster.yaml:
# volsync:
#   restic_password: "<generated-password>"
#   s3_access_key: "<set by bootstrap>"
#   s3_secret_key: "<set by bootstrap>"

# 3. Update kustomization files (manual - see deployment guide)
# Add volsync/ks.yaml to storage kustomization
# Add backup-ks.yaml entries to app kustomizations

# 4. Generate manifests
task configure --yes

# 5. Commit and push
git add .
git commit -m "feat(volsync): add automated PVC backups"
git push

# 6. Verify deployment
kubectl get pods -n volsync-system
kubectl get replicationsource -A

# 7. Trigger first backup
kubectl patch replicationsource immich-db-backup -n entertainment \
  --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"backup-$(date +%Y%m%d-%H%M%S)\"}}}"
```

## File Locations

All templates are in `templates/config/kubernetes/apps/`:

```
storage/volsync/           - Volsync deployment
entertainment/immich/backup/     - Immich DB backups
entertainment/kavita/backup/     - Kavita backups
default/homepage/backup/         - Homepage backups
observability/grafana/backup/    - Grafana backups
```

After running `task configure --yes`, manifests are generated in corresponding `kubernetes/apps/` directories.

## Key Features

✅ **Automated**: Daily backups with no manual intervention
✅ **Encrypted**: Restic encryption + SOPS for secrets
✅ **GitOps**: Fully declarative, managed by Flux
✅ **Efficient**: Longhorn snapshots for consistency
✅ **Retention**: Automatic pruning (7 daily, 4 weekly, 3 monthly)
✅ **Monitoring**: ServiceMonitor ready for Prometheus
✅ **Documented**: Complete deployment and restore procedures
✅ **RPi4-Optimized**: Resource limits tuned for low-power hardware

## Security

- ✅ Restic password stored encrypted with SOPS/age
- ✅ S3 credentials stored encrypted with SOPS/age  
- ✅ Backups encrypted at rest with Restic
- ✅ TLS for S3 communication to Garage
- ✅ Pods run as non-root (UID 65534)
- ✅ Seccomp profile enabled
- ✅ Capabilities dropped

## Next Steps

1. **Deploy** - Follow deployment guide to install Volsync
2. **Test** - Trigger manual backups and verify in Garage
3. **Restore Test** - Practice restore monthly (see restore procedures)
4. **Monitor** - Set up Prometheus alerts for failed/stale backups
5. **Expand** - Add backup configs for additional PVCs as needed

## Maintenance

### Monthly
- [ ] Test restore in backup-test namespace
- [ ] Verify all ReplicationSources show recent lastSyncTime
- [ ] Check S3 bucket usage
- [ ] Review Volsync logs for errors

### Quarterly  
- [ ] Practice disaster recovery drill
- [ ] Review and adjust retention policies
- [ ] Update documentation if configs changed

## Troubleshooting

See `docs/volsync-deployment-guide.md` for detailed troubleshooting.

Quick fixes:
- **Repository not found**: First backup initializes it
- **Permission denied**: Re-run `task storage:bootstrap-garage`
- **Backup pending**: Check PVC exists and Longhorn snapshot class

## Resources

- [Deployment Guide](./docs/volsync-deployment-guide.md)
- [Restore Procedures](./docs/volsync-restore-procedures.md)
- [Volsync Docs](https://volsync.readthedocs.io/)
- [Restic Docs](https://restic.readthedocs.io/)
- [Longhorn Docs](https://longhorn.io/docs/)

---

**Status**: ✅ Ready for deployment
**Date**: 2026-04-16
**Version**: 1.0
