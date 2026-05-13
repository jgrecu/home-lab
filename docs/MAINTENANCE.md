# Maintenance Guide

Regular maintenance procedures for the homelab Kubernetes cluster.

## Maintenance Schedule

| Task | Frequency | Responsibility |
|------|-----------|----------------|
| Check cluster health | Daily | Automated (Prometheus alerts) |
| Review backup status | Weekly | Manual review |
| Update Helm charts | Weekly | Renovate bot + manual approval |
| Update Talos/Kubernetes | Monthly | Tuppr (automated) |
| Review resource usage | Monthly | Manual review |
| Certificate renewal | Automatic | cert-manager |
| Disaster recovery test | Quarterly | Manual procedure |

## Daily Maintenance

### Automated Monitoring

Prometheus alerts will notify on:
- Pod failures (CrashLoopBackOff)
- High resource usage (>90% CPU/memory)
- Certificate expiration (<7 days)
- Backup failures (Volsync out of sync >1 hour)
- Storage exhaustion (>85% PVC usage)
- Flux reconciliation failures

**No action required unless alerts fire.**

### Manual Health Check (Optional)

```bash
# Quick cluster status
task ops:status

# Check for failed pods
task ops:pod-errors

# Review recent warning events
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20
```

## Weekly Maintenance

### Review Backup Status

**Check Volsync backups are running:**
```bash
task storage:backup-status
```

**Expected:** All ReplicationSources show recent `LAST_SYNC` timestamps (within 24 hours)

**If backup failed:**
1. Check logs: `kubectl logs -n volsync-system deploy/volsync-controller`
2. Follow troubleshooting guide: `docs/TROUBLESHOOTING.md#backup-failures`

### Review Renovate PRs

Renovate bot automatically creates PRs for:
- Helm chart updates
- Container image updates
- GitHub Action updates

**Review process:**
1. Check PR description for breaking changes
2. Review changelog link provided by Renovate
3. Merge if no breaking changes
4. Monitor Flux reconciliation after merge

**Auto-merge enabled for:**
- Patch version updates (x.y.Z)
- Digest updates (same version, new SHA)

**Manual review required for:**
- Minor version updates (x.Y.z)
- Major version updates (X.y.z)

### Check Prometheus Targets

**Verify all ServiceMonitors are being scraped:**
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
# Check all targets show "UP" status
```

**If targets are down:**
- Follow troubleshooting guide: `docs/TROUBLESHOOTING.md#monitoring--alerting`

## Monthly Maintenance

### Review Resource Usage

**Check node capacity:**
```bash
kubectl top nodes
```

**Review pod resource usage:**
```bash
kubectl top pods -A --sort-by=memory | head -20  # Top memory consumers
kubectl top pods -A --sort-by=cpu | head -20     # Top CPU consumers
```

**Check PVC usage:**
```bash
task storage:pvc-usage
```

**Actions if resource pressure detected:**
1. Identify top consumers
2. Review if resource requests/limits need adjustment
3. Consider scaling up nodes if cluster-wide pressure
4. Clean up unused PVCs/old data

### Talos/Kubernetes Updates

**Automated via Tuppr:**
- Maintenance window: Sundays 02:00 UTC
- Upgrades one node at a time
- Waits for node to be healthy before proceeding

**Manual check:**
```bash
# Check current Talos version
talosctl version --nodes <node-ip>

# Check current Kubernetes version
kubectl version --short

# Check for pending upgrades
kubectl get tuppr -A
```

**Configuration:**
- Tuppr config: `kubernetes/apps/system-upgrade/tuppr/`
- Documentation: `docs/tuppr-upgrades.md`

### Certificate Expiration Review

**Check certificates expiring soon:**
```bash
# Port forward to Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Query: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 30
# Shows certificates expiring within 30 days
```

**Normal:** cert-manager auto-renews 30 days before expiration  
**Alert:** If certificate shows <7 days and not renewing, investigate cert-manager logs

## Quarterly Maintenance

### Disaster Recovery Test

**Purpose:** Verify backup and restore procedures work

**Test procedure:**
1. Choose a non-critical application (e.g., homepage)
2. Take note of current state (screenshot, data verification)
3. Follow restore procedure: `docs/volsync-restore-procedures.md`
4. Verify restored data matches pre-restore state
5. Document any issues encountered

**Test schedule:** First Sunday of each quarter

## Upgrade Procedures

### Helm Chart Upgrades

**Automated** via Renovate + Flux:
1. Renovate creates PR with Helm chart update
2. Review changelog and breaking changes
3. Merge PR
4. Flux automatically applies HelmRelease update
5. Monitor pod rollout: `kubectl rollout status deployment <name> -n <namespace>`

**Manual helm upgrade** (emergency only):
```bash
# NOT RECOMMENDED - bypasses GitOps
helm upgrade <release> <chart> -n <namespace> --reuse-values --set image.tag=<new-tag>
```

Always prefer GitOps approach (update HelmRelease template, commit, push).

### Application Configuration Changes

**Template-driven workflow:**
```bash
# 1. Edit template
vim templates/config/kubernetes/apps/<namespace>/<app>/helmrelease.yaml.j2

# 2. Regenerate manifests
task configure --yes

# 3. Commit changes
git add -A
git commit -m "feat(<app>): update configuration"

# 4. Push
git push

# 5. Force reconciliation (optional, Flux auto-syncs within 10min)
flux reconcile kustomization <app> --with-source -n flux-system

# 6. Monitor rollout
kubectl get pods -n <namespace> --watch
```

### Node Maintenance

**Drain node for maintenance:**
```bash
# Cordon node (prevent new pods from scheduling)
kubectl cordon <node-name>

# Drain node (evict all pods gracefully)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Perform maintenance (hardware, OS updates, etc.)

# Uncordon node (allow scheduling again)
kubectl uncordon <node-name>
```

**Reboot node with Talos:**
```bash
talosctl reboot --nodes <node-ip>
```

**Node will automatically rejoin cluster after reboot.**

## Backup Management

### Backup Verification

**Check backup integrity monthly:**
```bash
# List all backups
task storage:backup-status

# Verify backup size is reasonable (not 0 bytes)
kubectl get replicationsource -A -o json | jq -r '.items[] | 
  "\(.metadata.namespace)/\(.metadata.name): Last sync \(.status.lastSyncTime)"'
```

### Backup Retention

Current retention policy (per application):
- Daily: 7 snapshots
- Weekly: 4 snapshots
- Monthly: 3 snapshots

**Total retention:** ~3 months of backups

**Adjust retention:**
Edit ReplicationSource `spec.restic.retain` in application template:
```yaml
restic:
  retain:
    daily: 7
    weekly: 4
    monthly: 3
```

## Storage Management

### Longhorn Maintenance

**Check volume health:**
```bash
task storage:longhorn-status
```

**Manually trigger replica rebuild** (if degraded):
```bash
# Access Longhorn UI
kubectl port-forward -n storage svc/longhorn-frontend 8000:80
# Open http://localhost:8000
# Select volume → "Create Replica"
```

### SeaweedFS S3 Storage

**Check SeaweedFS health:**
```bash
kubectl get pods -n storage -l app.kubernetes.io/name=seaweedfs
```

**Check S3 bucket usage:**
```bash
# List all buckets
kubectl exec -n storage seaweedfs-filer-0 -- weed shell << EOF
s3.bucket.list
EOF

# Check bucket sizes (via S3 API)
kubectl run -it --rm s3-debug --image=amazon/aws-cli --restart=Never -- \
  s3 --endpoint-url=http://seaweedfs-s3.storage.svc.cluster.local:8333 \
  ls s3://
```

## Security Maintenance

### Review SOPS-Encrypted Secrets

**Rotate encryption keys annually:**
```bash
# Generate new age key
age-keygen -o age-new.key

# Re-encrypt all secrets with new key
# (Detailed procedure TBD - requires re-encrypting all *.sops.yaml files)
```

### Review RBAC Permissions

**Audit ClusterRoles and RoleBindings quarterly:**
```bash
# List all ClusterRoleBindings
kubectl get clusterrolebindings

# Review high-privilege bindings
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | 
  select(.roleRef.name | contains("admin") or contains("cluster-admin")) |
  "\(.metadata.name): \(.subjects)"'
```

## Monitoring & Alerting Maintenance

### Grafana Dashboard Review

**Check dashboards are displaying data:**
```bash
kubectl port-forward -n observability svc/grafana 3000:3000
# Open http://localhost:3000
# Review each dashboard for missing data
```

**Update dashboards from Grafana community:**
- Longhorn dashboard: ID 13032
- cert-manager dashboard: ID 11001
- Flux dashboard: ID 16714

### Prometheus Alert Rules Review

**Test alert rules are firing correctly:**
```bash
# Access Prometheus Alerts UI
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/alerts
```

**Review alert history for false positives:**
- Adjust thresholds if too noisy
- Disable non-actionable alerts

## Documentation Maintenance

**Keep documentation up to date:**
- Update `CLAUDE.md` when adding new patterns or conventions
- Update `TROUBLESHOOTING.md` with new common issues
- Update `MAINTENANCE.md` with new procedures
- Document major changes in `docs/plans/`

## Emergency Procedures

### Cluster Unresponsive

1. **Check node status:**
   ```bash
   talosctl health --nodes <controlplane-ip>
   kubectl get nodes
   ```

2. **Check control plane components:**
   ```bash
   talosctl service status -n <controlplane-ip>
   ```

3. **Restart control plane if needed:**
   ```bash
   talosctl reboot --nodes <controlplane-ip>
   ```

### Complete Cluster Loss

**Disaster recovery procedure:**
1. Follow `docs/disaster-recovery.md`
2. Bootstrap new Talos cluster: `task bootstrap:talos`
3. Restore from Git: Flux will reconcile all apps
4. Restore PVCs from Volsync backups: `docs/volsync-restore-procedures.md`

### Data Corruption

**If application data is corrupted:**
1. Scale down application: `kubectl scale deployment <name> -n <namespace> --replicas=0`
2. Restore PVC from backup: `task storage:restore-pvc -- <namespace> <pvc-name> <capacity>`
3. Scale up application: `kubectl scale deployment <name> -n <namespace> --replicas=1`
4. Verify data integrity

## Contact & Support

**Internal documentation:**
- Troubleshooting: `docs/TROUBLESHOOTING.md`
- Disaster recovery: `docs/disaster-recovery.md`
- Volsync procedures: `docs/volsync-restore-procedures.md`
- Tuppr upgrades: `docs/tuppr-upgrades.md`

**External resources:**
- Talos documentation: https://www.talos.dev/
- Flux documentation: https://fluxcd.io/docs/
- Kubernetes documentation: https://kubernetes.io/docs/

---

## Expected Outcomes

After performing maintenance procedures, verify:

**System Health**:
```bash
kubectl get nodes
# Expected: All nodes Ready

kubectl get pods -A --field-selector=status.phase!=Running
# Expected: Empty (no failing pods)
```

**Flux Status**:
```bash
flux get kustomizations -A
# Expected: All showing "Applied" status
```

**Services Available**:
```bash
# Test key services respond
curl -f https://homepage.yourdomain.com
curl -f https://grafana.yourdomain.com
# Expected: HTTP 200 OK
```
