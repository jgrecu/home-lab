# Pod Security Standards (PSS) Guide

## Overview

This cluster enforces Kubernetes Pod Security Standards (PSS) at the namespace level. Understanding these policies is **critical** to avoid pod creation failures and deployment issues.

## What are Pod Security Standards?

PSS define three security profiles that restrict pod behavior:

1. **`privileged`** - Unrestricted, allows everything (insecure, avoid)
2. **`baseline`** - Minimally restrictive, prevents known privilege escalations
3. **`restricted`** - Heavily restricted, enforces pod hardening best practices

## Current Cluster Policy

**Default:** All namespaces are configured with `baseline` PSS unless specifically documented otherwise.

**Why baseline, not restricted?**
- Many common applications (media servers, CI/CD, home automation) cannot run under `restricted` due to:
  - Legacy container images without proper security contexts
  - Sidecar containers (exportarr, DinD) requiring relaxed permissions
  - Applications needing specific UIDs (e.g., root for cron jobs)
  - Lack of seccomp profiles in older images

## Namespace PSS Configuration

### Baseline Namespaces (Permissive)

These namespaces allow workloads with relaxed security requirements:

| Namespace | Reason | Notes |
|-----------|--------|-------|
| `cloud` | Nextcloud cron jobs run as root | CronJobs cannot set `runAsNonRoot=true` |
| `downloads` | Exportarr sidecars lack security contexts | Bazarr, Radarr, Sonarr, Prowlarr all use exportarr |
| `forgejo` | CI runner pods (future: may need DinD) | Currently using kube:// executor |
| `home-automation` | Home Assistant container requirements | Requires host network access, device privileges |
| `woodpecker` | CI/CD runner pods execute arbitrary workloads | Creates dynamic pods for build jobs |

### Restricted Namespaces (Strict)

These namespaces enforce strict security:

| Namespace | Apps | Requirements |
|-----------|------|-------------|
| `cert-manager` | cert-manager | Well-behaved, sets all security contexts |
| `database-system` | CloudNativePG, Dragonfly | Database operators with proper security |
| `flux-system` | Flux controllers | GitOps controllers are security-hardened |
| `kube-system` | Core Kubernetes | System components |
| `network` | Cilium, CoreDNS, Envoy Gateway | Network components with proper contexts |
| `observability` | Prometheus, Grafana, Loki | Monitoring stack is well-configured |
| `storage` | Longhorn, Volsync, CSI drivers | Storage operators with security contexts |
| `system-upgrade` | Tuppr | Upgrade controller is hardened |

## Common PSS Violations and Fixes

### Symptom: Pods Failing to Create

**Error message:**
```
Error creating: pods "app-xyz" is forbidden: violates PodSecurity "restricted:latest": 
allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false)
```

**Diagnosis:**
```bash
# Check namespace PSS labels
kubectl get namespace <namespace> -o yaml | grep pod-security

# Check recent pod creation failures
kubectl get events -n <namespace> --field-selector type=Warning --sort-by='.lastTimestamp' | tail -10

# Check replicaset events
kubectl describe rs -n <namespace> <replicaset-name>
```

### Solution 1: Relax Namespace PSS (Recommended)

**When to use:** The application legitimately needs relaxed security (common for legacy apps, CI/CD, home automation).

1. Edit namespace template:
```bash
# Edit templates/config/kubernetes/apps/<namespace>/namespace.yaml.j2
```

2. Change PSS labels:
```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: baseline  # was: restricted
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
```

3. Regenerate and apply:
```bash
task configure --yes
git add -A
git commit -m "fix(pss): relax <namespace> to baseline for <reason>"
git push
```

4. Wait for Flux to reconcile (or force):
```bash
flux reconcile kustomization cluster-apps --with-source
```

5. Restart affected deployments:
```bash
kubectl rollout restart deployment <app> -n <namespace>
```

### Solution 2: Fix Pod Security Context (Advanced)

**When to use:** You control the application and can modify its security context.

Add to HelmRelease or Deployment:
```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true  # if app supports it
```

## When Adding New Applications

### Pre-deployment Checklist

1. **Check namespace PSS policy:**
   ```bash
   kubectl get namespace <target-namespace> -o yaml | grep pod-security
   ```

2. **Understand app requirements:**
   - Does it need root access?
   - Does it use privileged containers?
   - Does it have sidecars (exportarr, DinD, etc.)?
   - Does the image set security contexts?

3. **Choose appropriate namespace:**
   - **Use existing baseline namespace** if app needs relaxed security
   - **Use restricted namespace** only if app is properly hardened
   - **Never create new namespaces without PSS labels**

4. **Test deployment:**
   ```bash
   # Dry-run to catch PSS violations early
   kubectl apply --dry-run=server -f kubernetes/apps/<namespace>/<app>/
   ```

### Common Application Patterns

#### Pattern 1: Media/Download Apps (Sonarr, Radarr, etc.)

**Namespace:** `downloads` (baseline)  
**Reason:** Exportarr sidecar lacks security contexts  
**Template location:** `templates/config/kubernetes/apps/downloads/<app>/`

#### Pattern 2: CI/CD Runners (Woodpecker, Forgejo Runner)

**Namespace:** `woodpecker` or `forgejo` (baseline)  
**Reason:** Dynamic pod creation for build jobs, may need Docker-in-Docker  
**Special note:** Prefer Kubernetes executor (`kube://`) over DinD when possible

#### Pattern 3: Home Automation

**Namespace:** `home-automation` (baseline)  
**Reason:** Device access, host network, hardware integration  
**Special note:** May need additional privileges via `allowPrivilegeEscalation: true`

#### Pattern 4: Databases & Storage

**Namespace:** `database-system` (restricted) or `storage` (restricted)  
**Reason:** Modern database operators set proper security contexts  
**Template example:** CloudNativePG, Dragonfly operators

## Troubleshooting PSS Issues

### Issue: Deployment Stuck at 0/1 Replicas

```bash
# Check replicaset status
kubectl get rs -n <namespace>

# Check replicaset events (look for "Error creating")
kubectl describe rs -n <namespace> <replicaset-name> | grep -A 10 "Events:"

# Check if namespace PSS changed
kubectl get namespace <namespace> -o yaml | grep pod-security
```

### Issue: App Was Working, Now Failing

**Possible causes:**
1. Namespace PSS was recently changed to `restricted`
2. Image was updated and removed security contexts
3. Kubernetes version upgrade enforced stricter PSS

**Solution:**
```bash
# Check recent namespace changes
git log --oneline -20 templates/config/kubernetes/apps/<namespace>/namespace.yaml.j2

# Check image changes
kubectl describe pod -n <namespace> <pod-name> | grep Image:

# Rollback or fix PSS
```

### Issue: Homepage Shows App as Offline

**Root cause:** Pod failed PSS validation and never started

**Check:**
```bash
# 1. Verify pods exist
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>

# 2. If no pods, check deployment
kubectl get deployment -n <namespace> <app>

# 3. Check replicaset events for PSS violations
kubectl describe rs -n <namespace> | grep -E "(Error creating|PodSecurity)"
```

## Best Practices

### DO ✅

- **Use `baseline` PSS for most application namespaces** - It's a pragmatic balance
- **Document why** each namespace uses baseline vs restricted (see tables above)
- **Test deployments** with `--dry-run=server` before committing
- **Check replicaset events** when pods won't start
- **Restart deployments** after changing namespace PSS labels

### DON'T ❌

- **Don't use `privileged` PSS** - There's almost never a legitimate need
- **Don't assume `restricted` is always correct** - Many apps can't meet those requirements
- **Don't edit cluster resources directly** - Always edit templates, regenerate, commit
- **Don't ignore PSS violations** - They indicate real security issues or configuration problems
- **Don't create namespaces without PSS labels** - They inherit cluster defaults (may be restrictive)

## Quick Reference Commands

```bash
# Check all namespace PSS policies
kubectl get namespaces -o custom-columns=NAME:.metadata.name,PSS:.metadata.labels.pod-security\\.kubernetes\\.io/enforce

# Find pods failing PSS
kubectl get events -A --field-selector type=Warning | grep "violates PodSecurity"

# Check specific namespace
kubectl describe namespace <namespace>

# Force reconcile after PSS change
flux reconcile kustomization cluster-apps --with-source

# Restart deployment to apply new PSS
kubectl rollout restart deployment <app> -n <namespace>
```

## References

- [Kubernetes Pod Security Standards Documentation](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- Cluster namespace templates: `templates/config/kubernetes/apps/*/namespace.yaml.j2`
- Troubleshooting guide: `docs/TROUBLESHOOTING.md`
