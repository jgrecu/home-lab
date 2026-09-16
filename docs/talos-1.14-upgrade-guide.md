# Talos 1.14 Upgrade Guide

## Why Manual Upgrade is Required

**Renovate cannot auto-detect Talos 1.14.0** because the `ghcr.io/siderolabs/installer` Docker image is no longer published starting with v1.14.0.

From [Talos 1.14.0 Release Notes](https://github.com/siderolabs/talos/releases/tag/v1.14.0):
> The `ghcr.io/siderolabs/installer` image is no longer published with releases; use the Image Factory installer image instead.

## Good News: You're Already Using Image Factory!

Your cluster is already configured to use Image Factory:
```yaml
# talos/talconfig.yaml (nodes)
talosImageURL: factory.talos.dev/installer/2dcd442954d67662d41c61bdb92165aaf7189aff9997bd011b6968c12ce8d9c0
```

**Your Schematic Includes:**
- `siderolabs/i915-ucode` - Intel graphics microcode
- `siderolabs/intel-ucode` - Intel CPU microcode  
- `siderolabs/iscsi-tools` - Required for Longhorn storage

## Why Upgrade to Talos 1.14?

**Required for Kubernetes 1.37 support:**
- Talos 1.13.x only supports up to Kubernetes 1.36.x
- Kubernetes 1.37.0 requires Talos 1.14.0+
- PR #470 (Kubernetes 1.37 upgrade) is blocked until this upgrade completes

**What Talos 1.14 Brings:**
- Kubernetes 1.37 compatibility
- Multi-document Kubernetes configuration
- LVM logical volume support
- Improved eBPF tooling compatibility
- NTS (Network Time Security) support for NTP

## Upgrade Process

### Step 1: Update Version in Templates

Edit **two template files** (never the generated files directly — they are overwritten by `task configure --yes`):

**`templates/config/talos/talenv.yaml.j2`:**

```bash
# Before:
talosVersion: v1.13.10

# After:
talosVersion: v1.14.1
```

**`templates/config/kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml.j2`:**

```bash
# Before:
    version: v1.13.10

# After:
    version: v1.14.1
```

> **Why two files?** `talenv.yaml.j2` drives talhelper config generation. The Tuppr policy has its own hardcoded version (with a Renovate annotation) that tells Tuppr which image to pull from Image Factory. They are independent — both must be updated.

**Note:** The Image Factory URL stays the same — no changes needed to `talos/talconfig.yaml`!

### Step 2: Regenerate Configurations

```bash
task configure --yes
```

This updates:
- `talos/talconfig.yaml` - Talos cluster config
- `kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml` - Tuppr upgrade policy

### Step 3: Commit and Push

```bash
git add talos/talenv.yaml kubernetes/ talos/
git commit -m "feat(talos): upgrade to v1.14.1 for Kubernetes 1.37 support"
git pull --rebase
git push
```

### Step 4: Let Flux Reconcile

```bash
# Force Flux to sync immediately
flux reconcile kustomization cluster-apps --with-source

# Watch Tuppr policy update
kubectl get talosupgrade -n system-upgrade cluster -w
```

### Step 5: Wait for Tuppr Maintenance Window

**Tuppr maintenance window:** Sundays at 02:00 UTC (4-hour window)

Tuppr will automatically:
1. Upgrade one node at a time
2. Wait for node to become Ready
3. Drain workloads before reboot
4. Move to next node only after health checks pass

**Monitor the upgrade:**
```bash
# Watch Tuppr status
kubectl describe talosupgrade cluster -n system-upgrade

# Watch nodes
kubectl get nodes -w

# Check Talos version on each node (during/after upgrade)
talosctl -n 192.168.1.160 version
talosctl -n 192.168.1.161 version
talosctl -n 192.168.1.162 version
```

### Step 6: Verify Upgrade Complete

After all nodes are upgraded:

```bash
# Verify all nodes on v1.14.1
kubectl get nodes -o wide

# Check Talos version
talosctl -n 192.168.1.160,192.168.1.161,192.168.1.162 version

# Verify cluster health
kubectl get pods -A | grep -v Running
```

### Step 7: Remove Kubernetes 1.37 Block

Once Talos 1.14 is deployed, remove the Renovate block:

Edit `.renovaterc.json5` and **remove or comment out** this rule (around line 57-65):
```json5
// {
//   description: 'Block Kubernetes 1.37 until Talos 1.14+ is deployed',
//   enabled: false,
//   matchDatasources: ['docker'],
//   matchPackageNames: [
//     'ghcr.io/siderolabs/kubelet',
//   ],
//   allowedVersions: '<1.37.0',
// },
```

Then commit and push - Renovate will reopen PR #470 or create a new one for Kubernetes 1.37.

## Rollback Plan

If something goes wrong during the upgrade:

```bash
# Revert the commit
git revert HEAD

# Push to trigger rollback
git push

# Tuppr will downgrade on next maintenance window
# OR manually downgrade with talosctl:
talosctl upgrade --image factory.talos.dev/installer/2dcd442954d67662d41c61bdb92165aaf7189aff9997bd011b6968c12ce8d9c0:v1.13.10 \
  --nodes 192.168.1.160,192.168.1.161,192.168.1.162
```

## Important Notes

1. **Two template files must be updated** — `templates/config/talos/talenv.yaml.j2` AND `templates/config/kubernetes/apps/system-upgrade/tuppr/policies/talosupgrade.yaml.j2`. Editing only one will leave Tuppr pointing at the old version.
2. **No Image Factory schematic changes needed** — your existing schematic works with v1.14.x
3. **Tuppr handles the upgrade automatically** — just update the version and wait for Sunday 02:00 UTC
4. **One node at a time** — upgrade is safe with health checks between each node
5. **Workloads keep running** — Longhorn replicates data across nodes during drain

## Breaking Changes in Talos 1.14

Most breaking changes don't affect typical homelab setups, but be aware:

- **Secure Boot images**: Default changed to `lockdown=integrity` (was `confidentiality`)
- **FlexVolume**: Removed (deprecated since Kubernetes 1.23)
- **iSCSI in-tree plugin**: Doesn't work with workload isolation enabled (doesn't affect Longhorn)

## References

- [Talos 1.14 Release Notes](https://github.com/siderolabs/talos/releases/tag/v1.14.0)
- [Talos Image Factory Documentation](https://www.talos.dev/latest/talos-guides/install/boot-assets/)
- [Tuppr Documentation](https://github.com/home-operations/tuppr)

## Timeline Estimate

- **Manual work:** 10-15 minutes (update version, commit, push)
- **Tuppr upgrade:** 1-2 hours (automatic, Sunday 02:00 UTC)
- **Total:** Plan for next Sunday maintenance window

---

**Last Updated:** 2026-09-16  
**Current Talos:** v1.14.1 (committed; Tuppr applies Sunday 02:00 UTC)  
**Previous Talos:** v1.13.10  
**Blocking:** Kubernetes 1.37 upgrade (PR #470) — unblock after Tuppr completes
