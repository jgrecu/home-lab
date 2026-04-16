# Volsync Restore Procedures

This document outlines procedures for restoring PVCs from Volsync backups stored in Garage S3.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Reference](#quick-reference)
- [Restore Procedures](#restore-procedures)
  - [1. In-Place Restore (Same Cluster)](#1-in-place-restore-same-cluster)
  - [2. Restore to New PVC](#2-restore-to-new-pvc)
  - [3. Disaster Recovery (New Cluster)](#3-disaster-recovery-new-cluster)
- [Application-Specific Restore Guides](#application-specific-restore-guides)
- [Troubleshooting](#troubleshooting)
- [Testing Your Backups](#testing-your-backups)

---

## Prerequisites

Before starting any restore operation, ensure you have:

- [ ] kubectl access to the cluster
- [ ] Volsync installed and running
- [ ] Restic secret with S3 credentials available
- [ ] Application scaled down (replicas=0) if doing in-place restore
- [ ] Recent backup timestamp noted from Garage S3 or Volsync status

### Verify Volsync Status

```bash
# Check Volsync is running
kubectl get pods -n volsync-system

# List all ReplicationSources (backups)
kubectl get replicationsource -A

# Check backup status for specific PVC
kubectl describe replicationsource <name> -n <namespace>
```

### List Available Backups

```bash
# Option 1: Via Volsync status
kubectl get replicationsource <name> -n <namespace> -o yaml | grep lastSyncTime

# Option 2: Via Restic CLI (requires restic secret)
# First, get the S3 credentials from the secret
kubectl get secret <restic-secret-name> -n <namespace> -o yaml

# Then use restic snapshots command (see examples below)
```

---

## Quick Reference

| Scenario | Method | Downtime | Data Loss Risk |
|----------|--------|----------|----------------|
| **Accidental file deletion** | In-place restore | ~5-15 min | Minimal (to last backup) |
| **PVC corruption** | Restore to new PVC | ~10-20 min | Minimal (to last backup) |
| **Cluster total loss** | Disaster recovery | ~30-60 min | Minimal (to last backup) |
| **Migration to new cluster** | Disaster recovery | ~30-60 min | None (controlled) |
| **Testing backups** | Restore to test namespace | 0 min | None (test only) |

---

## Restore Procedures

### 1. In-Place Restore (Same Cluster)

**Use Case**: Accidental deletion, file corruption, need to rollback to previous state

**Steps:**

#### Step 1: Scale Down Application

```bash
# For Deployments
kubectl scale deployment <app-name> -n <namespace> --replicas=0

# For StatefulSets
kubectl scale statefulset <app-name> -n <namespace> --replicas=0

# Verify pods are terminated
kubectl get pods -n <namespace>
```

#### Step 2: Create ReplicationDestination

Create a file `restore-<app-name>.yaml`:

```yaml
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app-name>-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: <app-name>-restic-secret  # Same secret as ReplicationSource
    destinationPVC: <original-pvc-name>   # The PVC to restore TO
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <original-size>              # e.g., 10Gi
    copyMethod: Direct                     # Overwrite existing PVC
    # Optional: restore from specific snapshot
    # restoreAsOf: "2026-04-15T10:30:00Z"
```

Apply it:

```bash
kubectl apply -f restore-<app-name>.yaml

# Watch restore progress
kubectl get replicationdestination <app-name>-restore -n <namespace> -w

# Check detailed status
kubectl describe replicationdestination <app-name>-restore -n <namespace>
```

#### Step 3: Verify Restore Completed

```bash
# Check ReplicationDestination status
kubectl get replicationdestination <app-name>-restore -n <namespace> -o jsonpath='{.status.lastSyncTime}'

# Check PVC is ready
kubectl get pvc <original-pvc-name> -n <namespace>
```

#### Step 4: Scale Application Back Up

```bash
# Scale up
kubectl scale deployment <app-name> -n <namespace> --replicas=1

# Verify application starts correctly
kubectl logs -n <namespace> deployment/<app-name> --tail=50 -f
```

#### Step 5: Cleanup

```bash
# Delete the ReplicationDestination (keep ReplicationSource for future backups)
kubectl delete replicationdestination <app-name>-restore -n <namespace>
```

---

### 2. Restore to New PVC

**Use Case**: PVC is corrupted, want to compare old vs new data, testing restore without affecting production

**Steps:**

#### Step 1: Create ReplicationDestination with New PVC

```yaml
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app-name>-restore-new
  namespace: <namespace>
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: <app-name>-restic-secret
    destinationPVC: <app-name>-restored  # NEW PVC name
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <size>
    copyMethod: Direct
```

#### Step 2: Wait for Restore to Complete

```bash
kubectl apply -f restore-<app-name>-new.yaml

# Wait for completion
kubectl wait --for=condition=Ready replicationdestination/<app-name>-restore-new -n <namespace> --timeout=600s
```

#### Step 3: Switch Application to New PVC

**Option A**: Update Helm values and reconcile via Flux

```yaml
# In your HelmRelease values
persistence:
  config:
    existingClaim: <app-name>-restored  # Changed from original
```

**Option B**: Manual kubectl patch (temporary)

```bash
kubectl scale deployment <app-name> -n <namespace> --replicas=0

kubectl patch deployment <app-name> -n <namespace> --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/volumes/0/persistentVolumeClaim/claimName",
    "value": "<app-name>-restored"
  }
]'

kubectl scale deployment <app-name> -n <namespace> --replicas=1
```

#### Step 4: Verify and Cleanup Old PVC

```bash
# Verify application works with restored PVC
kubectl logs -n <namespace> deployment/<app-name>

# Once confirmed working, delete old PVC
kubectl delete pvc <original-pvc-name> -n <namespace>

# Optionally rename the restored PVC (requires recreating with correct name)
```

---

### 3. Disaster Recovery (New Cluster)

**Use Case**: Complete cluster failure, migrating to new infrastructure, ransomware recovery

**Prerequisites:**
- New Talos cluster up and running
- Longhorn installed
- Volsync installed
- Restic secrets recreated with same S3 credentials

#### Step 1: Recreate Namespace and Secrets

```bash
# Create namespace
kubectl create namespace <namespace>

# Recreate Restic secret with S3 credentials
# Get the secret from your SOPS-encrypted config or password manager
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: <app-name>-restic-secret
  namespace: <namespace>
type: Opaque
stringData:
  RESTIC_REPOSITORY: s3:https://garage.jgrecu.dev/<bucket-name>/<path>
  RESTIC_PASSWORD: <restic-password>
  AWS_ACCESS_KEY_ID: <garage-access-key>
  AWS_SECRET_ACCESS_KEY: <garage-secret-key>
EOF
```

#### Step 2: Verify S3 Connectivity and Backup Exists

```bash
# Install restic locally (on your machine)
brew install restic  # macOS
# or apt install restic / dnf install restic

# Export credentials
export RESTIC_REPOSITORY=s3:https://garage.jgrecu.dev/<bucket-name>/<path>
export RESTIC_PASSWORD=<restic-password>
export AWS_ACCESS_KEY_ID=<garage-access-key>
export AWS_SECRET_ACCESS_KEY=<garage-secret-key>

# List snapshots
restic snapshots

# Note the snapshot ID you want to restore
```

#### Step 3: Create ReplicationDestination for Each PVC

```yaml
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app-name>-dr-restore
  namespace: <namespace>
spec:
  trigger:
    manual: dr-restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: <app-name>-restic-secret
    destinationPVC: <pvc-name>
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <size>
    copyMethod: Direct
    # Optional: restore specific snapshot
    # restoreAsOf: "2026-04-15T10:30:00Z"
```

Apply for each critical PVC:

```bash
# Immich database
kubectl apply -f restore-immich-db.yaml

# Kavita config
kubectl apply -f restore-kavita-config.yaml

# etc...
```

#### Step 4: Wait for All Restores

```bash
# Watch all ReplicationDestinations
kubectl get replicationdestination -n <namespace> -w

# Check specific restore status
kubectl describe replicationdestination <app-name>-dr-restore -n <namespace>
```

#### Step 5: Deploy Applications via Flux

```bash
# If using Flux, reconcile the cluster to deploy applications
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Applications will start and mount the restored PVCs
```

#### Step 6: Verify Application Data

```bash
# Check application logs
kubectl logs -n <namespace> deployment/<app-name>

# Port-forward and verify data in UI
kubectl port-forward -n <namespace> svc/<app-name> 8080:80

# Open http://localhost:8080 and verify data is present
```

#### Step 7: Resume Backups

```bash
# ReplicationSources should be deployed by Flux
# Verify they're running and starting new backup cycles
kubectl get replicationsource -A

# Check first backup after restore completes
kubectl describe replicationsource <app-name>-backup -n <namespace>
```

---

## Application-Specific Restore Guides

### Immich Database

```bash
# 1. Scale down Immich
kubectl scale deployment immich-server -n entertainment --replicas=0
kubectl scale deployment immich-ml -n entertainment --replicas=0

# 2. Restore database PVC
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: immich-db-restore
  namespace: entertainment
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: immich-db-restic-secret
    destinationPVC: immich-db
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: 10Gi
    copyMethod: Direct
EOF

# 3. Wait for completion
kubectl wait --for=condition=Ready replicationdestination/immich-db-restore -n entertainment --timeout=600s

# 4. Scale up Immich
kubectl scale deployment immich-server -n entertainment --replicas=1
kubectl scale deployment immich-ml -n entertainment --replicas=1

# 5. Verify
kubectl logs -n entertainment deployment/immich-server --tail=50
```

### Kavita Config

```bash
# Kavita stores library DB in config PVC
kubectl scale deployment kavita -n entertainment --replicas=0

kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: kavita-config-restore
  namespace: entertainment
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: kavita-config-restic-secret
    destinationPVC: kavita-config
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: 2Gi
    copyMethod: Direct
EOF

kubectl wait --for=condition=Ready replicationdestination/kavita-config-restore -n entertainment --timeout=600s
kubectl scale deployment kavita -n entertainment --replicas=1
```

### Homepage Config

```bash
# Homepage dashboard config
kubectl scale deployment homepage -n default --replicas=0

kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: homepage-config-restore
  namespace: default
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: homepage-restic-secret
    destinationPVC: homepage
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: 1Gi
    copyMethod: Direct
EOF

kubectl wait --for=condition=Ready replicationdestination/homepage-config-restore -n default --timeout=600s
kubectl scale deployment homepage -n default --replicas=1
```

### Grafana Database

```bash
# Grafana dashboards and datasources
kubectl scale deployment grafana -n observability --replicas=0

kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: grafana-restore
  namespace: observability
spec:
  trigger:
    manual: restore-$(date +%Y%m%d-%H%M%S)
  restic:
    repository: grafana-restic-secret
    destinationPVC: grafana
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: 5Gi
    copyMethod: Direct
EOF

kubectl wait --for=condition=Ready replicationdestination/grafana-restore -n observability --timeout=600s
kubectl scale deployment grafana -n observability --replicas=1
```

---

## Troubleshooting

### Restore Stuck in Pending

**Symptoms**: ReplicationDestination stays in pending state

**Check:**
```bash
# Check pod logs
kubectl logs -n <namespace> -l volsync.backube/replicationdestination=<name>

# Check events
kubectl describe replicationdestination <name> -n <namespace>

# Common issues:
# - Restic secret not found or incorrect credentials
# - PVC already exists with data
# - No S3 connectivity to Garage
```

**Solution:**
```bash
# Verify secret exists
kubectl get secret <restic-secret-name> -n <namespace>

# Test S3 connectivity from a debug pod
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -I https://garage.jgrecu.dev

# Delete and recreate ReplicationDestination with correct settings
```

### Restore Fails with "Repository Not Found"

**Symptoms**: Error message about repository not being initialized

**Solution:**
```bash
# Check if repository path in secret is correct
kubectl get secret <restic-secret-name> -n <namespace> -o jsonpath='{.data.RESTIC_REPOSITORY}' | base64 -d

# Verify backups exist in Garage
# Use Garage admin UI or AWS CLI
aws s3 ls --endpoint-url https://garage.jgrecu.dev s3://<bucket-name>/<path>/

# If repository doesn't exist, you may have wrong bucket/path
# Check the ReplicationSource that created the backups
kubectl get replicationsource <name> -n <namespace> -o yaml | grep repository
```

### Application Fails to Start After Restore

**Symptoms**: Pod CrashLoopBackOff after restore

**Check:**
```bash
# Check application logs
kubectl logs -n <namespace> <pod-name>

# Check PVC is mounted
kubectl describe pod <pod-name> -n <namespace> | grep -A 10 Volumes

# Check filesystem inside PVC
kubectl exec -it <pod-name> -n <namespace> -- ls -la /path/to/mount

# Common issues:
# - Permissions wrong after restore
# - Database needs recovery/repair
# - Config files malformed
```

**Solution:**
```bash
# Fix permissions (example for PostgreSQL)
kubectl exec -it <pod-name> -n <namespace> -- chown -R postgres:postgres /var/lib/postgresql/data

# Run database repair (example for PostgreSQL)
kubectl exec -it <postgres-pod> -n <namespace> -- psql -U postgres -c "REINDEX DATABASE <dbname>;"

# If all else fails, restore to a new PVC and compare files
```

### Slow Restore Performance

**Expected restore times** (for reference):
- 1GB PVC: ~2-5 minutes
- 10GB PVC: ~10-20 minutes
- 100GB PVC: ~60-120 minutes

**If slower than expected:**

```bash
# Check network throughput to Garage
kubectl run -it --rm speedtest --image=curlimages/curl --restart=Never -- \
  curl -o /dev/null https://garage.jgrecu.dev/large-file.bin

# Check Longhorn volume performance
kubectl get volumes -n longhorn-system

# Check if Volsync is resource-constrained
kubectl top pod -n volsync-system

# Increase resources for Volsync if needed (edit HelmRelease values)
```

### Point-in-Time Restore Not Working

**Issue**: `restoreAsOf` timestamp not finding snapshot

**Solution:**
```bash
# List available snapshots with exact timestamps
restic -r s3:https://garage.jgrecu.dev/<bucket>/<path> snapshots

# Use the exact timestamp from snapshot list
# Format: YYYY-MM-DDTHH:MM:SSZ

# Example:
restoreAsOf: "2026-04-15T02:30:15Z"
```

---

## Testing Your Backups

**CRITICAL**: Never assume backups work. Test them regularly!

### Monthly Backup Test Procedure

**Goal**: Verify you can restore from backups without affecting production

#### Test Restore to Separate Namespace

```bash
# 1. Create test namespace
kubectl create namespace backup-test

# 2. Copy Restic secret to test namespace
kubectl get secret <app-name>-restic-secret -n <namespace> -o yaml | \
  sed 's/namespace: .*/namespace: backup-test/' | \
  kubectl apply -f -

# 3. Create test ReplicationDestination
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
    repository: <app-name>-restic-secret
    destinationPVC: test-restored-data
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <size>
    copyMethod: Direct
EOF

# 4. Wait for restore
kubectl wait --for=condition=Ready replicationdestination/test-restore -n backup-test --timeout=600s

# 5. Mount PVC in debug pod and verify data
kubectl run -it --rm debug -n backup-test \
  --image=busybox \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "debug",
      "image": "busybox",
      "command": ["/bin/sh"],
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/data"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "test-restored-data"
      }
    }]
  }
}' \
  -- ls -laR /data

# 6. Document results in a log
echo "$(date): Backup test successful for <app-name>" >> ~/backup-test-log.txt

# 7. Cleanup
kubectl delete namespace backup-test
```

### Backup Health Checklist

Run this monthly:

- [ ] All ReplicationSources show recent `lastSyncTime`
- [ ] No failed backups in Volsync logs
- [ ] S3 bucket usage is growing appropriately
- [ ] Test restore completed successfully
- [ ] Retention policy is working (old snapshots being pruned)
- [ ] Documentation is up to date with any configuration changes

```bash
# Quick health check script
cat > backup-health-check.sh <<'EOF'
#!/bin/bash
echo "=== Volsync Backup Health Check ==="
echo ""

echo "ReplicationSources:"
kubectl get replicationsource -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
LAST_SYNC:.status.lastSyncTime,\
DURATION:.status.lastSyncDuration

echo ""
echo "Recent Volsync Errors:"
kubectl logs -n volsync-system -l control-plane=volsync --tail=50 | grep -i error

echo ""
echo "S3 Bucket Usage:"
# Requires aws CLI configured with Garage credentials
aws s3 ls --endpoint-url https://garage.jgrecu.dev --recursive s3://volsync-backups/ --summarize | tail -2
EOF

chmod +x backup-health-check.sh
./backup-health-check.sh
```

---

## Recovery Time Objectives (RTO)

Expected recovery times for your home lab:

| Scenario | RTO Target | Notes |
|----------|------------|-------|
| **Single PVC restore** | 15-30 minutes | App downtime during restore |
| **Multiple PVCs (5-10)** | 1-2 hours | Can restore in parallel |
| **Full cluster rebuild** | 4-6 hours | Includes Talos setup, app deployment |
| **Selective app restore** | 30 minutes | Just one app with dependencies |

## Recovery Point Objectives (RPO)

Data loss tolerance based on backup schedule:

| Backup Frequency | RPO (Max Data Loss) | Recommended For |
|------------------|---------------------|-----------------|
| **Hourly** | 1 hour | Critical databases (Immich) |
| **Daily (2 AM)** | 24 hours | Application configs |
| **Weekly** | 7 days | Test environments |

---

## Automation Suggestions

### Automated Restore Validation

Create a CronJob to periodically test restores:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-validation
  namespace: backup-test
spec:
  schedule: "0 3 1 * *"  # Monthly on 1st at 3 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-tester
          containers:
          - name: restore-test
            image: ghcr.io/backube/volsync:latest
            command:
            - /bin/sh
            - -c
            - |
              # Script to create ReplicationDestination, wait, verify, cleanup
              # Send results to Slack/Discord/Email
          restartPolicy: OnFailure
```

### Backup Monitoring with Prometheus

Alert when backups fail or are stale:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: volsync-alerts
  namespace: observability
spec:
  groups:
  - name: volsync
    interval: 5m
    rules:
    - alert: VolsyncBackupFailed
      expr: |
        volsync_replicationsource_last_sync_status == 0
      for: 1h
      annotations:
        summary: "Volsync backup failed for {{ $labels.name }}"
        description: "ReplicationSource {{ $labels.namespace }}/{{ $labels.name }} has failed backups"
    
    - alert: VolsyncBackupStale
      expr: |
        time() - volsync_replicationsource_last_sync_timestamp > 86400
      for: 1h
      annotations:
        summary: "Volsync backup is stale for {{ $labels.name }}"
        description: "No successful backup in 24 hours for {{ $labels.namespace }}/{{ $labels.name }}"
```

---

## Additional Resources

- [Volsync Documentation](https://volsync.readthedocs.io/)
- [Restic Documentation](https://restic.readthedocs.io/)
- [Longhorn Backup & Restore](https://longhorn.io/docs/latest/snapshots-and-backups/)
- [Garage S3 Documentation](https://garagehq.deuxfleurs.fr/documentation/)

---

## Document Maintenance

**Last Updated**: 2026-04-16  
**Tested On**: Talos v1.9.x, Longhorn v1.8.x, Volsync v0.10.x  
**Maintained By**: Home Lab Operations  

**Change Log**:
- 2026-04-16: Initial document creation
- _Next review date: 2026-05-16_
