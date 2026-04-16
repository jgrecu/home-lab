# Disaster Recovery Guide

This guide covers recovery procedures for accidental deletions and catastrophic failures in your Kubernetes cluster.

## Table of Contents

- [Understanding the Backup System](#understanding-the-backup-system)
- [What Happens During Accidental Deletion](#what-happens-during-accidental-deletion)
- [Why Automatic Restore is NOT Enabled](#why-automatic-restore-is-not-enabled)
- [Manual Restore Procedures](#manual-restore-procedures)
- [Common Disaster Scenarios](#common-disaster-scenarios)
- [Protection Mechanisms](#protection-mechanisms)
- [Best Practices](#best-practices)

---

## Understanding the Backup System

Your cluster uses **three backup systems** (all to Garage S3):

| System | What It Backs Up | Automatic Restore? |
|--------|------------------|-------------------|
| **Volsync** | Application PVCs (config, state) | ❌ No - Manual only |
| **CNPG** | PostgreSQL databases | ❌ No - Manual only |
| **Longhorn** | Volume snapshots (via Volsync) | ❌ No - Manual only |

**Key Point**: None of these systems automatically restore data when an app is deleted and recreated.

---

## What Happens During Accidental Deletion

### Scenario: You accidentally delete the Forgejo namespace

```bash
kubectl delete namespace forgejo
```

### Automatic Actions (Flux GitOps)

Within 1-5 minutes, Flux will:

1. ✅ Detect that `forgejo` namespace is missing
2. ✅ Recreate the namespace
3. ✅ Recreate all Kubernetes resources:
   - CNPG PostgreSQL cluster
   - Deployment, Service, HTTPRoute
   - ConfigMaps, Secrets
   - PVCs (forgejo-data, forgejo-postgres PVCs)
4. ✅ Start pods

### What You Get

- ⚠️ **Empty PVCs** - No data restored
- ⚠️ **Empty database** - CNPG creates fresh database
- ⚠️ **Fresh installation** - All repos, issues, PRs lost

### What Volsync Does (or Doesn't Do)

- ❌ Does NOT detect the PVC was deleted
- ❌ Does NOT automatically restore from backup
- ⚠️ **Will create new backups of the empty PVC** on next schedule
- 💾 **Old backups remain safe in Garage** (until retention expires)

---

## Why Automatic Restore is NOT Enabled

This behavior is **intentional** for several important reasons:

### 1. Ambiguity of Intent

When a PVC is deleted, the system cannot know if:
- 🤔 It was accidental (should restore)
- 🤔 You wanted to start fresh (should NOT restore)
- 🤔 You're migrating/renaming (should restore to different location)

### 2. Data Safety

Automatic restore could:
- Overwrite intentional changes
- Restore stale data over newer data
- Cause conflicts with running applications

### 3. Point-in-Time Control

You might want to restore:
- Latest backup (default)
- Backup from 1 week ago (before corruption)
- Backup from 1 month ago (before bad migration)

Automatic restore would only give you "latest."

### 4. Validation Opportunity

Manual restore lets you:
- Verify the backup exists
- Check backup integrity
- Test restore in a temporary PVC first
- Review what data will be restored

---

## Manual Restore Procedures

### Quick Restore (Using Taskfile)

**Simplest method** - Use the provided task:

```bash
# Syntax
task storage:restore-pvc -- <namespace> <pvc-name> <capacity>

# Examples
task storage:restore-pvc -- forgejo forgejo-data 20Gi
task storage:restore-pvc -- entertainment immich-db 10Gi
task storage:restore-pvc -- cloud nextcloud-html 10Gi
task storage:restore-pvc -- default homepage 1Gi
```

**What the task does**:
1. Finds deployments using the PVC
2. Scales them down to 0 replicas
3. Deletes the existing (empty) PVC
4. Creates a Volsync ReplicationDestination
5. Waits for restore to complete
6. Scales deployments back up

**Time**: 5-15 minutes depending on PVC size

### Manual Restore (Step by Step)

If you prefer to do it manually or need more control:

#### Step 1: Stop the Application

```bash
# Scale down to prevent writes to PVC
kubectl scale deployment -n <namespace> <app-name> --replicas=0

# Wait for pods to terminate
kubectl wait --for=delete pod -l app.kubernetes.io/name=<app-name> -n <namespace> --timeout=60s
```

#### Step 2: Delete the Empty PVC

```bash
# Delete the PVC created by Flux (it's empty anyway)
kubectl delete pvc -n <namespace> <pvc-name>

# Wait for deletion to complete
kubectl wait --for=delete pvc/<pvc-name> -n <namespace> --timeout=120s
```

#### Step 3: Create ReplicationDestination

```bash
# This tells Volsync to restore from backup
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <pvc-name>-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: <pvc-name>-restic-secret
    destinationPVC: <pvc-name>
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: <capacity>
    copyMethod: Direct
EOF
```

#### Step 4: Wait for Restore

```bash
# Monitor restore progress
kubectl get replicationdestination -n <namespace> <pvc-name>-restore -w

# Or wait for completion (timeout 10 minutes)
kubectl wait --for=condition=complete \
  replicationdestination/<pvc-name>-restore \
  -n <namespace> --timeout=600s
```

#### Step 5: Clean Up and Restart

```bash
# Remove the ReplicationDestination
kubectl delete replicationdestination -n <namespace> <pvc-name>-restore

# Scale application back up
kubectl scale deployment -n <namespace> <app-name> --replicas=1

# Verify pod starts and data is present
kubectl logs -n <namespace> -l app.kubernetes.io/name=<app-name> -f
```

---

## Common Disaster Scenarios

### Scenario 1: Accidentally Deleted Namespace

**Example**: `kubectl delete namespace forgejo`

**Recovery**:

1. **Don't panic** - Flux will recreate everything automatically
2. **Wait for Flux reconciliation** (1-5 minutes):
   ```bash
   # Force immediate reconciliation
   flux reconcile kustomization forgejo --with-source
   ```
3. **Wait for pods to start** (they'll have empty data)
4. **Restore PVCs**:
   ```bash
   # Application data
   task storage:restore-pvc -- forgejo forgejo-data 20Gi
   ```
5. **Restore database** (if applicable):
   ```bash
   # CNPG will attempt auto-recovery from Garage
   # If that fails, see "Database Recovery" section below
   ```

**Total Time**: 10-20 minutes  
**Data Loss**: None (if backups exist from before deletion)

### Scenario 2: Corrupted PVC Data

**Example**: Forgejo database corrupted, app won't start

**Recovery**:

1. **Identify the issue**:
   ```bash
   kubectl logs -n forgejo -l app.kubernetes.io/name=forgejo
   ```

2. **Scale down the app**:
   ```bash
   kubectl scale deployment -n forgejo forgejo --replicas=0
   ```

3. **Choose restore point**:
   - Latest backup (most recent)
   - Backup from before corruption started

4. **Restore to a test PVC first** (optional but recommended):
   ```bash
   # Modify the script or ReplicationDestination to use a different PVC name
   # Test that data is good before replacing production PVC
   ```

5. **Delete corrupt PVC and restore**:
   ```bash
   kubectl delete pvc -n forgejo forgejo-data
   task storage:restore-pvc -- forgejo forgejo-data 20Gi
   ```

**Total Time**: 15-30 minutes  
**Data Loss**: Changes since last backup (max 24 hours with daily backups)

### Scenario 3: Database Corruption

**Example**: Immich PostgreSQL database corrupted

**Recovery using CNPG**:

CNPG has built-in point-in-time recovery (PITR) from WAL archives:

```bash
# Check available backups
kubectl exec -n entertainment immich-postgres-1 -- \
  psql -U postgres -c "SELECT * FROM pg_available_backups();"

# To restore, you need to recreate the cluster with recovery bootstrap
# This is complex - see CNPG documentation or contact support
```

**Alternative - Restore from Volsync backup of DB PVC**:

If Immich DB PVC is backed up by Volsync:

```bash
task storage:restore-pvc -- entertainment immich-db 10Gi
```

**Total Time**: 30-60 minutes  
**Data Loss**: Minimal (WAL archives capture transactions up to deletion)

### Scenario 4: Entire Cluster Lost

**Example**: All nodes destroyed, starting fresh

**Recovery**:

This is the **full disaster recovery** scenario.

1. **Build new cluster**:
   - Deploy Talos on new nodes
   - Use same cluster name and network configuration
   - Apply Flux GitOps configuration

2. **Bootstrap Garage** (if NAS survived):
   ```bash
   # Garage data on NAS is intact, just reconnect
   task storage:bootstrap-garage
   ```

3. **Deploy all apps via Flux**:
   ```bash
   flux reconcile kustomization flux-system --with-source
   ```

4. **Wait for apps to deploy** (empty PVCs will be created)

5. **Restore all PVCs** (in order of dependencies):
   ```bash
   # Core services first
   task storage:restore-pvc -- default homepage 1Gi
   task storage:restore-pvc -- observability grafana 1Gi

   # Applications
   task storage:restore-pvc -- forgejo forgejo-data 20Gi
   task storage:restore-pvc -- cloud nextcloud-html 10Gi
   task storage:restore-pvc -- entertainment immich-db 10Gi
   task storage:restore-pvc -- entertainment kavita-config 2Gi
   task storage:restore-pvc -- home-automation home-assistant-config 5Gi
   
   # Databases will auto-recover from CNPG backups in Garage
   ```

6. **Verify all services**:
   ```bash
   kubectl get pods -A
   kubectl get httproute -A
   ```

**Total Time**: 4-8 hours (depending on data size and parallelization)  
**Data Loss**: Changes since last backup (max 24 hours for PVCs)

### Scenario 5: Accidental File Deletion Inside a PVC

**Example**: Deleted critical files from Nextcloud data directory

**Recovery**:

You can restore to a **temporary PVC** and copy specific files:

1. **Restore to temporary PVC**:
   ```bash
   # Modify script to create nextcloud-html-temp instead
   # Or manually create ReplicationDestination with different PVC name
   ```

2. **Mount both PVCs** (original + restored):
   ```bash
   kubectl run -n cloud file-recovery --image=alpine --rm -it \
     --overrides='
     {
       "spec": {
         "containers": [{
           "name": "recovery",
           "image": "alpine",
           "command": ["sh"],
           "volumeMounts": [
             {"name": "original", "mountPath": "/original"},
             {"name": "restored", "mountPath": "/restored"}
           ]
         }],
         "volumes": [
           {"name": "original", "persistentVolumeClaim": {"claimName": "nextcloud-html"}},
           {"name": "restored", "persistentVolumeClaim": {"claimName": "nextcloud-html-temp"}}
         ]
       }
     }' \
     -- sh
   
   # Inside the pod, copy specific files
   cp -a /restored/path/to/deleted/files /original/path/to/
   ```

3. **Clean up temporary PVC**:
   ```bash
   kubectl delete pvc -n cloud nextcloud-html-temp
   ```

**Total Time**: 15-30 minutes  
**Data Loss**: None (surgical file recovery)

---

## Protection Mechanisms

### What DOES Protect You

#### 1. Flux GitOps

- ✅ Automatically recreates deleted resources
- ✅ Ensures cluster state matches Git
- ✅ Does NOT delete resources unless removed from Git
- ⚠️ By default, `prune: false` - resources won't be auto-deleted

#### 2. Namespace Finalizers

- ✅ Namespace deletion takes 30-60 seconds
- ✅ Gives you time to notice and cancel:
  ```bash
  # If you catch it in time
  kubectl patch namespace <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
  ```

#### 3. Volsync Backups (Manual Restore)

- ✅ Daily backups to Garage S3
- ✅ 6-month retention (7 daily, 8 weekly, 6 monthly)
- ✅ Restic deduplication saves space
- ⚠️ Requires manual restore (see above)

#### 4. CNPG Continuous WAL Archiving

- ✅ PostgreSQL transactions backed up continuously
- ✅ Point-in-time recovery capability
- ✅ 180-day retention
- ⚠️ Requires manual recovery process

#### 5. Longhorn Volume Replicas

- ✅ 2 replicas across nodes (survives 1 node failure)
- ⚠️ Does NOT protect against:
  - Namespace deletion (PVC is deleted too)
  - Intentional PVC deletion
  - Data corruption within the volume

### What Does NOT Protect You

#### ❌ Automatic PVC Restore

- Volsync does NOT automatically restore
- You must manually trigger restore

#### ❌ PVC Reclaim Policy

- Default Longhorn `reclaimPolicy: Delete`
- Deleting PVC also deletes underlying volume
- ⚠️ Consider changing to `Retain` for critical PVCs

#### ❌ Accidental `kubectl delete`

- No "recycle bin" for Kubernetes resources
- Once confirmed, deletion is immediate
- Only Flux or manual recreation brings it back

#### ❌ Backup of Backups

- Garage S3 data is not backed up elsewhere
- If NAS dies, backups are lost
- **Recommendation**: Use NAS RAID or replicate to offsite S3

---

## Best Practices

### Prevention (Avoiding Disasters)

#### 1. Use Labels to Prevent Accidental Deletion

```bash
# Add protection label to critical namespaces
kubectl label namespace forgejo protected=true

# Never delete namespaces with this label
kubectl get namespace -l protected=true
```

#### 2. Alias Dangerous Commands

Add to your shell profile (`~/.bashrc` or `~/.zshrc`):

```bash
# Require confirmation before deleting namespaces
alias kubectl-delete-ns='echo "⚠️  Are you SURE? Type namespace name to confirm:" && read NS && kubectl delete namespace $NS'
```

#### 3. Use Dry-Run First

```bash
# Always dry-run destructive operations
kubectl delete namespace forgejo --dry-run=client

# If satisfied, remove --dry-run
kubectl delete namespace forgejo
```

#### 4. Enable Audit Logging

Track who deleted what:

```yaml
# In Talos machine config
cluster:
  apiServer:
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      rules:
        - level: RequestResponse
          verbs: ["delete"]
```

#### 5. Regular Restore Testing

**Test your backups monthly**:

```bash
# Restore to temporary namespace for testing
# This verifies backups are working AND you know the process

# Example: Test Forgejo restore
kubectl create namespace forgejo-test
# Follow restore procedure, test, then clean up
kubectl delete namespace forgejo-test
```

### Monitoring and Alerts

#### 1. Monitor Backup Job Success

```bash
# Check ReplicationSource status regularly
kubectl get replicationsource -A

# Failed backups will show "Failed" condition
```

#### 2. Alert on Missing Backups

Set up alerts for:
- ⚠️ Volsync backup job failures
- ⚠️ Backup age >48 hours (stale backups)
- ⚠️ CNPG backup failures

#### 3. Monitor Garage Storage Usage

```bash
# Check bucket sizes
kubectl exec -n storage garage-0 -- garage bucket info volsync-backups

# Alert when >80% full
```

### Recovery Readiness

#### 1. Keep Documentation Accessible

- 📄 Store this guide outside the cluster (printed or on laptop)
- 📄 Document your specific PVC names and capacities
- 📄 Keep Garage S3 credentials in password manager

#### 2. Maintain Off-Cluster Access

- 💾 Keep `kubeconfig` backed up outside cluster
- 💾 Keep `age.key` (SOPS encryption) backed up securely
- 💾 Keep Garage admin credentials accessible

#### 3. Practice Recovery Procedures

- 🎯 Run through scenarios quarterly
- 🎯 Time yourself (is it under SLA?)
- 🎯 Update documentation based on lessons learned

---

## Quick Reference

### Service-Specific Restore Commands

```bash
# Homepage
task storage:restore-pvc -- default homepage 1Gi

# Grafana
task storage:restore-pvc -- observability grafana 1Gi

# Home Assistant
task storage:restore-pvc -- home-automation home-assistant-config 5Gi

# Nextcloud (config only, not user data)
task storage:restore-pvc -- cloud nextcloud-html 10Gi

# Forgejo
task storage:restore-pvc -- forgejo forgejo-data 20Gi

# Immich (PostgreSQL DB PVC)
task storage:restore-pvc -- entertainment immich-db 10Gi

# Kavita
task storage:restore-pvc -- entertainment kavita-config 2Gi
```

### Verification Commands

```bash
# Check PVC is bound
kubectl get pvc -n <namespace> <pvc-name>

# Check pod is running
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>

# Check application logs
kubectl logs -n <namespace> -l app.kubernetes.io/name=<app> -f

# Test application via port-forward
kubectl port-forward -n <namespace> svc/<service> 8080:80
```

### List Available Backups

```bash
# Port-forward to Garage
kubectl port-forward -n storage svc/garage-s3 3900:3900

# Export credentials (get from cluster.yaml or Garage bootstrap output)
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"

# List Volsync backups
aws s3 ls s3://volsync-backups/ --recursive --endpoint-url http://localhost:3900

# List CNPG backups
aws s3 ls s3://cnpg-backups/ --recursive --endpoint-url http://localhost:3900
```

---

## Summary

✅ **Backups exist** - Volsync, CNPG, and Longhorn all back up to Garage  
⚠️ **Restore is manual** - You must trigger restoration explicitly  
🎯 **Use the task** - `task storage:restore-pvc -- <namespace> <pvc> <size>`  
📚 **Test regularly** - Practice restores quarterly  
🛡️ **Prevent accidents** - Use labels, aliases, and dry-runs  
⏱️ **Time to recovery** - Most scenarios: 10-30 minutes  

**Your data is safe** as long as:
- Volsync backups are running (check `kubectl get replicationsource -A`)
- Garage is healthy and has space
- You follow the restore procedures in this guide

When in doubt: **Don't panic, check backups exist, then restore methodically.** 🧘
