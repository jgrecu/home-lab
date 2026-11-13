# Volsync Deployment Guide

This guide walks you through deploying Volsync for automated PVC backups to SeaweedFS S3.

## Prerequisites

- ✅ Talos cluster running
- ✅ Longhorn storage deployed
- ✅ SeaweedFS S3 storage deployed
- ✅ Argo CD GitOps configured

## Step 1: Bootstrap SeaweedFS with Volsync Bucket

The `just ops bootstrap-seaweedfs` command now automatically creates the `volsync-backups` bucket.

```bash
# Run the bootstrap command
just ops bootstrap-seaweedfs
```

This will:
- Create `volsync-backups` bucket in SeaweedFS
- Generate S3 access keys (if not exists)
- Grant permissions to the key

## Step 2: Add Secrets to Vault

Store the Volsync S3 credentials and restic password in Vault so ESO can sync them into Kubernetes Secrets:

```bash
# Generate a secure restic password
RESTIC_PASSWORD=$(openssl rand -base64 32)

# Store credentials in Vault (adjust keys to match your SeaweedFS bootstrap output)
vault kv put secret-kv2/volsync/seaweedfs \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  AWS_ACCESS_KEY_ID="<seaweedfs-access-key>" \
  AWS_SECRET_ACCESS_KEY="<seaweedfs-secret-key>"

# Store per-app restic repository paths (one entry per PVC)
vault kv put secret-kv2/volsync/immich-db \
  RESTIC_REPOSITORY="s3:http://seaweedfs-filer.storage.svc.cluster.local:8333/volsync-backups/immich-db"
```

## Step 3: Update Kustomization Files

Add the Volsync and backup kustomizations to the appropriate files:

### Add to `kubernetes/apps/storage/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./longhorn/ks.yaml
  - ./seaweedfs/ks.yaml
  - ./volsync/ks.yaml        # <-- Add this line
```

### Add to `kubernetes/apps/entertainment/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./immich/ks.yaml
  - ./immich/backup-ks.yaml   # <-- Add this line
  - ./kavita/ks.yaml
  - ./kavita/backup-ks.yaml   # <-- Add this line
  - ./seerr/ks.yaml
  - ./jellyfin/ks.yaml
```

### Add to `kubernetes/apps/default/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./echo/ks.yaml
  - ./homepage/ks.yaml
  - ./homepage/backup-ks.yaml  # <-- Add this line
```

### Add to `kubernetes/apps/observability/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./kube-prometheus-stack/ks.yaml
  - ./grafana/ks.yaml
  - ./grafana/backup-ks.yaml   # <-- Add this line
  - ./gatus/ks.yaml
  - ./kromgo/ks.yaml
```

## Step 4: Add ExternalSecret Manifests

Add `ExternalSecret` manifests to `kubernetes/apps/<namespace>/<app>/backup/` following the pattern in any existing backup directory. ESO will sync the credentials from Vault into Kubernetes Secrets for Volsync to use.

## Step 5: Commit and Push

```bash
# Check what was added
git status

# Review the changes
git diff kubernetes/

# Add all changes
git add kubernetes/

# Commit
git commit -m "feat(volsync): add automated PVC backups to SeaweedFS S3

- Deploy Volsync for backup automation
- Configure ReplicationSources for critical PVCs:
  - immich-db (daily at 2:30 AM)
  - kavita-config (daily at 3:00 AM)
  - homepage config (daily at 3:15 AM)
  - grafana (daily at 3:30 AM)
- Retention: 7 daily, 4 weekly, 3 monthly backups
- Target: SeaweedFS S3 volsync-backups bucket"

# Push: the GitHub webhook triggers the Argo CD sync
git push
```

## Step 6: Verify Deployment

### Watch Volsync Installation

```bash
# Watch Volsync deployment
kubectl get pods -n volsync-system -w

# Check the Argo CD Application
kubectl -n argo-system get application volsync
```

Expected output:
```
NAME     REVISION  SUSPENDED  READY  MESSAGE
volsync  0.10.x    False      True   Helm install succeeded
```

### Verify ReplicationSources

```bash
# List all backup sources
kubectl get replicationsource -A

# Expected output:
NAMESPACE        NAME                    SOURCE        LAST SYNC
default          homepage-config-backup  homepage      <none>  (will sync at scheduled time)
entertainment    immich-db-backup        immich-db     <none>
entertainment    kavita-config-backup    kavita-config <none>
observability    grafana-backup          grafana       <none>
```

### Check ExternalSecrets Are Synced

```bash
# Verify ExternalSecrets are synced (STATUS should be SecretSynced / READY True)
kubectl get externalsecret -n entertainment
kubectl get externalsecret -n default
kubectl get externalsecret -n observability
```

## Step 7: Trigger First Backup (Manual)

Don't wait for the schedule - trigger a backup immediately to verify everything works:

```bash
# Trigger Immich backup
kubectl patch replicationsource immich-db-backup -n entertainment \
  --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"backup-$(date +%Y%m%d-%H%M%S)\"}}}"

# Watch the backup job
kubectl get pods -n entertainment -l volsync.backube/replicationsource=immich-db-backup -w
```

### Monitor Backup Progress

```bash
# Check ReplicationSource status
kubectl describe replicationsource immich-db-backup -n entertainment

# Check for successful completion
kubectl get replicationsource immich-db-backup -n entertainment \
  -o jsonpath='{.status.lastSyncTime}'
```

Expected successful output:
```
2026-04-16T14:30:45Z
```

### Verify Backup in SeaweedFS

```bash
# Port-forward to SeaweedFS S3
kubectl port-forward -n storage svc/seaweedfs-s3 8333:8333

# List backups in S3 bucket (in another terminal)
aws s3 ls s3://volsync-backups/ \
  --endpoint-url http://localhost:8333 \
  --access-key-id "<your-key>" \
  --secret-access-key "<your-secret>"

# Expected output shows subdirectories for each PVC:
PRE immich-db/
PRE kavita-config/
PRE homepage-config/
PRE grafana/
```

## Step 8: Set Up Monitoring (Optional but Recommended)

### Add Prometheus Alerts

Check if ServiceMonitor was created:

```bash
kubectl get servicemonitor -n volsync-system
```

Add alerts to your Prometheus rules (if using kube-prometheus-stack):

```yaml
# Create kubernetes/apps/observability/kube-prometheus-stack/app/volsync-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: volsync-backup-alerts
  namespace: observability
spec:
  groups:
  - name: volsync
    interval: 5m
    rules:
    - alert: VolsyncBackupFailed
      expr: volsync_replicationsource_last_sync_status == 0
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "Volsync backup failed"
        description: "ReplicationSource {{ $labels.namespace }}/{{ $labels.name }} has failed"
    
    - alert: VolsyncBackupStale
      expr: (time() - volsync_replicationsource_last_sync_timestamp) > 172800
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "Volsync backup is stale"
        description: "No successful backup for {{ $labels.namespace }}/{{ $labels.name }} in 48 hours"
```

## Backup Schedule Summary

| Application | PVC | Schedule | Retention |
|-------------|-----|----------|-----------|
| Immich DB | `immich-db` | Daily 2:30 AM | 7d/4w/3m |
| Kavita | `kavita-config` | Daily 3:00 AM | 7d/4w/3m |
| Homepage | `homepage` | Daily 3:15 AM | 7d/4w/3m |
| Grafana | `grafana` | Daily 3:30 AM | 7d/4w/3m |

## Troubleshooting

### Backup Job Fails with "Repository Not Found"

**Cause**: Restic repository hasn't been initialized

**Solution**: The first backup will initialize the repository automatically. Check logs:

```bash
kubectl logs -n entertainment -l volsync.backube/replicationsource=immich-db-backup
```

### "Permission Denied" Errors

**Cause**: S3 credentials incorrect or permissions not granted

**Solution**:
```bash
# Re-run bootstrap to grant permissions
just ops bootstrap-seaweedfs

# Update Vault credentials if they changed
vault kv patch secret-kv2/volsync/seaweedfs \
  AWS_ACCESS_KEY_ID="<new-key>" \
  AWS_SECRET_ACCESS_KEY="<new-secret>"

# Force ESO to re-sync the secret
kubectl annotate externalsecret immich-db-restic -n entertainment \
  force-sync=$(date +%s) --overwrite
```

### Backup Job Stuck in Pending

**Check**:
```bash
kubectl describe replicationsource <name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Common causes:
- PVC doesn't exist
- Longhorn snapshot class not found
- Insufficient resources

### Test Restore

See `docs/volsync-restore-procedures.md` for complete restore procedures.

Quick test:
```bash
# Create test namespace
kubectl create namespace backup-test

# Copy secret
kubectl get secret immich-db-restic-secret -n entertainment -o yaml | \
  sed 's/namespace: entertainment/namespace: backup-test/' | \
  kubectl apply -f -

# Create ReplicationDestination
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: test-restore
  namespace: backup-test
spec:
  trigger:
    manual: test-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: immich-db-restic-secret
    destinationPVC: test-restored-data
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: 10Gi
    copyMethod: Direct
EOF

# Wait and verify
kubectl wait --for=condition=Ready replicationdestination/test-restore -n backup-test --timeout=600s
kubectl run -it --rm verify -n backup-test --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"verify","image":"busybox","command":["/bin/sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"test-restored-data"}}]}}' \
  -- ls -la /data

# Cleanup
kubectl delete namespace backup-test
```

## Next Steps

1. **Test Restores Monthly** - Use the procedures in `docs/volsync-restore-procedures.md`
2. **Add More Apps** - Create ReplicationSource configs for additional PVCs
3. **Monitor Backup Health** - Set up alerts and dashboards
4. **Document RTO/RPO** - Define recovery time and recovery point objectives
5. **Disaster Recovery Drill** - Practice full cluster restore annually

## Additional Resources

- [Volsync Documentation](https://volsync.readthedocs.io/)
- [Restore Procedures](./volsync-restore-procedures.md)
- [Restic Documentation](https://restic.readthedocs.io/)
- [SeaweedFS S3 API Docs](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)

## Quick Command Reference

```bash
# List all backups
kubectl get replicationsource -A

# Check backup status
kubectl describe replicationsource <name> -n <namespace>

# Trigger manual backup
kubectl patch replicationsource <name> -n <namespace> \
  --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"backup-$(date +%Y%m%d-%H%M%S)\"}}}"

# View backup logs
kubectl logs -n <namespace> -l volsync.backube/replicationsource=<name>

# Check S3 bucket contents
kubectl port-forward -n storage svc/seaweedfs-s3 8333:8333
aws s3 ls s3://volsync-backups/ --recursive \
  --endpoint-url http://localhost:8333 \
  --access-key-id "<your-key>" \
  --secret-access-key "<your-secret>"

# Force a refresh of every Application (backups are part of each app)
just reconcile
```
