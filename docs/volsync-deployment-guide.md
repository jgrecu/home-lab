# Volsync Deployment Guide

This guide walks you through deploying Volsync for automated PVC backups to Garage S3.

## Prerequisites

- ✅ Talos cluster running
- ✅ Longhorn storage deployed
- ✅ Garage S3 storage deployed
- ✅ Flux GitOps configured

## Step 1: Bootstrap Garage with Volsync Bucket

The `task storage:bootstrap-garage` command now automatically creates the `volsync-backups` bucket.

```bash
# Run the bootstrap task
task storage:bootstrap-garage
```

This will:
- Create `volsync-backups` bucket in Garage
- Generate S3 access keys (if not exists)
- Grant permissions to the key
- Update `cluster.yaml` with credentials

## Step 2: Add Volsync Configuration to cluster.yaml

Edit `cluster.yaml` and add the Volsync section (if not already present):

```yaml
# cluster.yaml

# ... existing config ...

# Volsync backup configuration
volsync:
  # Generate a secure Restic password
  # openssl rand -base64 32
  restic_password: ""  # Will be encrypted by SOPS

  # S3 credentials (set by bootstrap-garage task)
  s3_access_key: ""     # Set by bootstrap-garage
  s3_secret_key: ""     # Set by bootstrap-garage, will be encrypted
```

### Generate Restic Password

```bash
# Generate a secure password for Restic encryption
openssl rand -base64 32

# Copy the output and paste it into cluster.yaml under volsync.restic_password
```

**Example:**
```yaml
volsync:
  restic_password: "xK8vQ2mP9nL7sJ5hF3tR6wE1yU4iO0aZ2cB8dN5gH7j="
  s3_access_key: "GK1234567890abcdef"
  s3_secret_key: "secretkeythatwassetbytheboostrapscript"
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
  - ./garage/ks.yaml
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

## Step 4: Generate Kubernetes Manifests

```bash
# Regenerate all Kubernetes manifests from templates
# This will encrypt secrets with SOPS automatically
task configure --yes
```

This will:
- Render all templates with your cluster.yaml values
- Encrypt all `*.sops.yaml` files with your age key
- Validate manifests with kubeconform

## Step 5: Commit and Push

```bash
# Check what was generated
git status

# Review the changes
git diff kubernetes/

# Add all changes
git add kubernetes/ templates/

# Commit
git commit -m "feat(volsync): add automated PVC backups to Garage S3

- Deploy Volsync for backup automation
- Configure ReplicationSources for critical PVCs:
  - immich-db (daily at 2:30 AM)
  - kavita-config (daily at 3:00 AM)
  - homepage config (daily at 3:15 AM)
  - grafana (daily at 3:30 AM)
- Retention: 7 daily, 4 weekly, 3 monthly backups
- Target: Garage S3 volsync-backups bucket"

# Push to trigger Flux reconciliation
git push
```

## Step 6: Verify Deployment

### Watch Volsync Installation

```bash
# Watch Volsync deployment
kubectl get pods -n volsync-system -w

# Check HelmRelease
flux get helmrelease -n volsync-system volsync
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

### Check Backup Secrets

```bash
# Verify secrets are created (encrypted with SOPS)
kubectl get secret -n entertainment | grep restic
kubectl get secret -n default | grep restic
kubectl get secret -n observability | grep restic
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

### Verify Backup in Garage

```bash
# List backups in S3 bucket
kubectl run -it --rm aws-cli --image=amazon/aws-cli --restart=Never -- \
  --endpoint-url https://garage.jgrecu.dev \
  s3 ls s3://volsync-backups/

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
task storage:bootstrap-garage

# Regenerate manifests
task configure --yes

# Force secret recreation
kubectl delete secret immich-db-restic-secret -n entertainment
flux reconcile kustomization immich-backup
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
- [Garage S3 API Docs](https://garagehq.deuxfleurs.fr/documentation/)

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
kubectl run -it --rm aws-cli --image=amazon/aws-cli --restart=Never -- \
  --endpoint-url https://garage.jgrecu.dev \
  s3 ls s3://volsync-backups/ --recursive

# Force reconcile all backups
flux reconcile kustomization immich-backup
flux reconcile kustomization kavita-backup
flux reconcile kustomization homepage-backup
flux reconcile kustomization grafana-backup
```
