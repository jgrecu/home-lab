# Tuppr - Automated Talos and Kubernetes Upgrades

## Overview

**Tuppr** is an automated upgrade controller for Talos OS and Kubernetes in your homelab cluster. It manages safe, scheduled upgrades with health checks and maintenance windows.

## What Tuppr Does

1. **Monitors for upgrades**: Watches `TalosUpgrade` and `KubernetesUpgrade` custom resources
2. **Scheduled maintenance windows**: Only performs upgrades during defined time windows
3. **Safe sequential upgrades**: 
   - Upgrades Talos OS first
   - Then upgrades Kubernetes control plane
   - One node at a time (parallelism: 1)
4. **Health checks**: Waits for each node to be Ready before proceeding to the next
5. **Graceful drains**: Properly drains workloads before upgrading nodes

## Configuration

### Maintenance Window

- **Schedule**: Sundays at 02:00 UTC
- **Duration**: 4 hours
- **Purpose**: Aligns with Renovate schedule so version bump PRs merged on weekends trigger upgrades the same night

### Talos Upgrade Policy

Location: `kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml`

```yaml
spec:
  talos:
    version: v1.13.0  # Target version
  
  policy:
    debug: true
    force: false
    rebootMode: default      # Graceful shutdown and reboot
    placement: soft          # Prefers non-critical nodes first
    timeout: 30m            # Max time for entire upgrade
  
  healthChecks:
    - apiVersion: v1
      kind: Node
      expr: status.conditions.exists(c, c.type == "Ready" && c.status == "True")
      timeout: 10m          # Max wait for Node Ready
  
  drain:
    deleteLocalData: true
    ignoreDaemonSets: true
    force: true
```

### Kubernetes Upgrade Policy

Location: `kubernetes/apps/system-upgrade/tuppr/policies/kubernetesupgrade.yaml`

```yaml
spec:
  kubernetes:
    version: v1.36.0  # Target version
  
  healthChecks:
    - apiVersion: v1
      kind: Node
      expr: status.conditions.exists(c, c.type == "Ready" && c.status == "True")
      timeout: 10m
  
  maintenance:
    windows:
      - start: "0 2 * * 0"  # Sunday 02:00 UTC
        duration: "4h"
        timezone: "UTC"
```

## How Upgrades Work

### Upgrade Sequence

When the maintenance window opens (Sunday 02:00 UTC):

#### 1. Talos OS Upgrade (v1.12.6 → v1.13.0)
- Drain `m900-ctrl` node
- Upgrade Talos OS to target version
- Reboot node
- Wait for node to be Ready (max 10 minutes)
- Proceed to `m900-wrk1` node
- Drain, upgrade, reboot
- Wait for node to be Ready
- Complete

#### 2. Kubernetes Upgrade (v1.35.3 → v1.36.0)
- Upgrade control plane on `m900-ctrl`
- Wait for health checks to pass
- Upgrade kubelet on `m900-wrk1`
- Wait for health checks to pass
- Complete

### Safety Mechanisms

- **Sequential processing**: Only one node at a time
- **Health check gates**: Won't proceed if previous node isn't healthy
- **Timeout protection**: Fails safe if operations take too long
- **No forced upgrades**: Won't bypass health checks (force: false)

## Monitoring Upgrades

### Check Current Status

```bash
# View upgrade resources and their status
kubectl get talosupgrade,kubernetesupgrade -n system-upgrade

# Detailed status information
kubectl describe talosupgrade cluster -n system-upgrade
kubectl describe kubernetesupgrade kubernetes -n system-upgrade

# Watch upgrade progress in real-time
kubectl get talosupgrade,kubernetesupgrade -n system-upgrade -w
```

### Check Tuppr Controller Logs

```bash
# View recent logs
kubectl logs -n system-upgrade deployment/tuppr --tail=50

# Follow logs during upgrade
kubectl logs -n system-upgrade deployment/tuppr -f
```

### Status Phases

- **MaintenanceWindow**: Waiting for scheduled maintenance window
- **InProgress**: Actively upgrading nodes
- **Completed**: Upgrade finished successfully
- **Failed**: Upgrade encountered an error

## Troubleshooting

### Health Check Failures

**What happens when health checks fail:**

1. **Tuppr stops immediately**: No automatic retry
2. **Node marked as failed**: Recorded in `failedNodes` status field
3. **Error logged**: Recorded in `lastError` status field
4. **Phase changes to Failed**: Visible in status

**Why no automatic retry?**
- Safety first: A failed health check indicates something is wrong
- Human intervention needed: Automatic retries could make things worse
- Prevents cascading failures: Won't continue if one node fails

### Recovery Options

#### Option 1: Investigate and Fix

```bash
# Check the failure details
kubectl describe talosupgrade cluster -n system-upgrade

# Investigate the failed node
kubectl describe node <failed-node>
kubectl get events --all-namespaces --sort-by='.lastTimestamp'

# Check tuppr logs for errors
kubectl logs -n system-upgrade deployment/tuppr --tail=100

# Fix the underlying issue (depends on what failed)
# Examples:
# - Node stuck booting: Check Talos console
# - Pods not scheduling: Check resource availability
# - Network issues: Check CNI status
```

#### Option 2: Force Retry (after fixing the issue)

```bash
# Delete the upgrade resource
kubectl delete talosupgrade cluster -n system-upgrade

# Flux will recreate it from git
# It will retry in the next maintenance window
```

#### Option 3: Rollback

```bash
# Edit the version in templates
vim templates/config/talos/talenv.yaml
# Change: talosVersion: v1.12.6  (rollback)

vim templates/config/kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml
# Change: version: v1.12.6

# Regenerate and commit
task configure --yes
git add -A
git commit -m "rollback: revert Talos to v1.12.6"
git push

# Flux will apply the rollback spec
```

### Common Issues

#### Node Doesn't Come Back After Reboot

**Symptoms**: Health check times out waiting for Node Ready

**Possible causes**:
- Talos failed to boot
- Network configuration issue
- API server unreachable

**Resolution**:
```bash
# Check Talos console for boot errors
# Access via IPMI/iLO or physical console

# Check if node is pingable
ping 192.168.1.160

# Check Talos API
talosctl --nodes 192.168.1.160 version

# If needed, manually revert via Talos recovery
```

#### Pods Stuck in Pending After Upgrade

**Symptoms**: Health check passes but workloads don't reschedule

**Possible causes**:
- Resource pressure
- Affinity/anti-affinity conflicts
- PVC mount issues

**Resolution**:
```bash
# Check pod status
kubectl get pods --all-namespaces --field-selector=status.phase=Pending

# Describe stuck pods
kubectl describe pod <pod-name> -n <namespace>

# Check node resources
kubectl describe node <node-name>
```

## Updating Target Versions

### 1. Update Templates

Edit `templates/config/talos/talenv.yaml`:
```yaml
talosVersion: v1.13.0
kubernetesVersion: v1.36.0
```

Edit `templates/config/kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml`:
```yaml
spec:
  talos:
    version: v1.13.0
```

Edit `templates/config/kubernetes/apps/system-upgrade/tuppr/policies/kubernetesupgrade.yaml`:
```yaml
spec:
  kubernetes:
    version: v1.36.0
```

### 2. Regenerate and Commit

```bash
# Regenerate manifests
task configure --yes

# Commit changes
git add -A
git commit -m "feat(upgrades): update Talos to v1.13.0 and Kubernetes to v1.36.0"
git push
```

### 3. Flux Reconciles Automatically

Flux will:
1. Detect the new versions in git
2. Update the `TalosUpgrade` and `KubernetesUpgrade` resources
3. Tuppr will schedule the upgrade for the next maintenance window

## Triggering Manual Upgrades

To upgrade immediately (outside maintenance window):

### Option 1: Remove Maintenance Window Temporarily

```bash
# Edit the policy to remove maintenance window
kubectl edit talosupgrade cluster -n system-upgrade

# Remove the entire maintenance.windows section
# Save and exit - upgrade starts immediately
```

### Option 2: Force via Annotation

```bash
# Annotate the resource to bypass maintenance window
kubectl annotate talosupgrade cluster -n system-upgrade \
  tuppr.home-operations.com/force-upgrade="true"

# Upgrade starts immediately
```

**⚠️ Warning**: Manual upgrades bypass safety windows. Only use when necessary.

## Best Practices

### Before Upgrades

1. **Backup important data**: Ensure PVC backups are current
2. **Check cluster health**: Ensure all nodes and pods are healthy
3. **Review changelog**: Read Talos and Kubernetes release notes
4. **Test in dev first**: If possible, test the upgrade in a dev environment

### During Upgrades

1. **Monitor actively**: Watch logs and status during maintenance window
2. **Don't interrupt**: Let tuppr complete its process
3. **Check intermediate states**: Verify each node after upgrade

### After Upgrades

1. **Verify cluster health**: Check all nodes and pods
2. **Test critical workloads**: Ensure applications work correctly
3. **Check logs**: Review for any warnings or errors
4. **Update documentation**: Note any issues encountered

## Architecture

### Components

- **tuppr controller**: Runs in `system-upgrade` namespace
- **TalosUpgrade CRD**: Defines Talos OS upgrade policy
- **KubernetesUpgrade CRD**: Defines Kubernetes upgrade policy
- **Flux**: Deploys and manages tuppr resources from git

### Dependencies

- **Talos API**: Used to perform OS upgrades
- **Kubernetes API**: Used for health checks and drains
- **Flux GitOps**: Manages upgrade policy from git

### Resource Flow

```
Git Repository
  └─> Flux (flux-system namespace)
      └─> Kustomization (system-upgrade)
          ├─> tuppr Helm Release
          │   └─> tuppr controller (deployment)
          └─> tuppr policies
              ├─> TalosUpgrade resource
              └─> KubernetesUpgrade resource
```

## References

- [Talos System Upgrades](https://www.talos.dev/latest/talos-guides/upgrading/talos/)
- [Kubernetes Version Skew Policy](https://kubernetes.io/releases/version-skew-policy/)
- [Tuppr GitHub Repository](https://github.com/home-operations/tuppr)

## Current Configuration

**Cluster Status** (as of last check):
- **Running**: Talos v1.12.6, Kubernetes v1.35.3
- **Target**: Talos v1.13.0, Kubernetes v1.36.0
- **Next maintenance window**: Check with `kubectl describe talosupgrade cluster -n system-upgrade`
- **Controller status**: `kubectl get pods -n system-upgrade`
