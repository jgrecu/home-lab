# Deferred Features and Blocked Work

This document tracks features and improvements that are blocked by upstream dependencies or external factors.

## Forgejo Runner - Kubernetes Native Execution

**Status:** ⏸️ **DEFERRED** - Runner deployment removed, waiting for upstream support  
**Date Deferred:** 2026-05-13  
**Date Removed:** 2026-06-01  
**Tracked Issue:** N/A (Forgejo runner is early stage)  
**Review Date:** 2026-09-01 (3-month check for upstream progress)

### Summary

Attempted to migrate Forgejo runner from Docker-in-Docker (DinD) to Kubernetes native pod execution using `kube://` executor labels. Configuration was correct, but **the runner daemon has a hard requirement for Docker socket presence at startup**, even when using Kubernetes-only execution mode.

**Decision (2026-06-01):** Removed Forgejo runner deployment from cluster. Using **Woodpecker CI** for Kubernetes-native CI/CD instead. Woodpecker is already deployed and working with Kubernetes backend (no Docker socket required).

### What Was Attempted

**Configuration (all correct):**
- ✅ Set `kube://docker.io/node:20-bookworm` labels in runner registration
- ✅ Configured RBAC with pod creation permissions
- ✅ Set namespace PSS to `baseline` (allows runner pod)
- ✅ Removed `DOCKER_HOST` environment variable
- ✅ Created `config.yaml` with runner settings
- ✅ ServiceAccount token mounting enabled
- ✅ Post-renderer patches serviceAccountName correctly

**Blocker:**
```
Error: daemon Docker Engine socket not found and docker_host config was invalid
```

This error occurs during daemon **startup validation**, before the runner reads labels or config. The check is hardcoded in the binary.

### Root Cause

The Forgejo runner (which wraps ACT runner) performs a Docker environment validation during initialization:
1. Looks for Docker socket at `/var/run/docker.sock`
2. Checks `DOCKER_HOST` environment variable
3. Validates `docker_host` config field
4. **Exits if none found**, regardless of executor type

The `kube://` labels only determine job execution backend - they don't affect daemon startup requirements.

### Why Not Docker-in-Docker?

DinD requires:
- `privileged: true` security context
- Violates Pod Security Standards (PSS) `baseline` and `restricted` policies
- Security risk (container escape, kernel exploits)
- Resource overhead (nested Docker daemon)

**Kubernetes native execution is superior:**
- Each job = separate pod (better isolation)
- Native Kubernetes RBAC and security policies
- Automatic cleanup via pod garbage collection
- Scales with cluster capacity
- No privileged containers needed

### Alternative: Woodpecker CI (Current Solution)

**Woodpecker CI is already deployed and working** in this cluster with Kubernetes native execution:
- Namespace: `woodpecker`
- PSS: `baseline` (CI runners need relaxed security)
- Executor: Kubernetes native (not DinD)
- Jobs spawn as separate pods successfully
- **NO Docker socket required**

**Architecture (as of 2026-06-01):**
```
┌─────────────┐
│   Forgejo   │  Git hosting, code review, repositories
│  (forgejo)  │  Lightweight, privacy-focused
└──────┬──────┘
       │ webhook triggers
       ▼
┌─────────────┐
│ Woodpecker  │  CI/CD execution
│  (woodpecker)│  Kubernetes-native jobs (WOODPECKER_BACKEND: "kubernetes")
└─────────────┘
```

**Trade-off:** Using Woodpecker instead of Forgejo Actions means:
- Forgejo repository still available for git hosting ✅
- CI/CD workflows run in Woodpecker (separate UI) ⚠️
- Both are Drone CI forks with similar YAML syntax ✅
- Resource efficient: ~300MB total (Forgejo 200MB + Woodpecker 100MB) ✅

**Why This Works:**
- Separation of concerns: Git hosting ≠ CI/CD platform
- Woodpecker has mature Kubernetes executor (no Docker socket)
- Lightweight and perfect for homelab constraints

### What Would Unblock This

**Upstream changes needed:**

1. **Add `--no-docker-check` flag** to forgejo-runner daemon command
   - Skip Docker socket validation at startup
   - Only validate executor backends when jobs are claimed

2. **Add Kubernetes-only build** of the runner
   - Compile without Docker client library
   - Pure Kubernetes executor

3. **Environment variable:** `FORGEJO_RUNNER_SKIP_DOCKER_CHECK=true`
   - Runtime flag to bypass validation
   - Backwards compatible with existing deployments

**How to track upstream:**
- Watch Forgejo repository: https://code.forgejo.org/forgejo/runner
- Check releases for "kubernetes" or "no-docker" mentions
- Subscribe to Forgejo Actions discussions

### Commits Related to This Work

- `30e10365` - forgejo namespace PSS relaxed to baseline
- `a641d5f4` - Removed DOCKER_HOST env var
- `b4491aa6` - Added config.yaml with runner settings

**Configuration preserved in templates (ready for future re-enablement):**
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/helmrelease.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/rbac.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/kustomization.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/ocirepository.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/secret.sops.yaml.j2`

**Deployment status:** Runner removed from `kubernetes/`, referenced commented out in kustomization.
When upstream adds support, uncomment the line in `templates/config/kubernetes/apps/forgejo/kustomization.yaml.j2` and regenerate.

### Review Checklist (2026-09-01)

**Automated reminder scheduled via CronCreate.**

- [ ] Check Forgejo runner releases for Kubernetes improvements
  - Visit: https://code.forgejo.org/forgejo/runner/releases
  - Look for: "kubernetes", "no-docker", "--no-docker-check" flag mentions
- [ ] Search Gitea act_runner for similar improvements (Forgejo uses this)
  - Visit: https://gitea.com/gitea/act_runner/releases
- [ ] Test if new runner version works without Docker socket
  - Uncomment runner in kustomization
  - Run `task configure --yes`
  - Deploy and observe startup logs
- [ ] Compare with alternatives: Is GitLab or other solution now better?
- [ ] Evaluate Woodpecker CI satisfaction: Are we happy with current setup?
- [ ] If still blocked, defer review to 2026-12-01 (6-month check)

### Documentation

**Full migration plan:** `docs/plans/forgejo-runner-kubernetes-executor.md` (local only, not in git)

**Related:**
- `docs/pod-security-standards.md` - PSS policies and CI/CD patterns
- `kubernetes/apps/woodpecker/` - Working Kubernetes executor example

---

## Template for New Deferred Items

```markdown
## <Feature Name>

**Status:** ⏸️ **DEFERRED** - <Reason>  
**Date Deferred:** YYYY-MM-DD  
**Tracked Issue:** <URL or N/A>  
**Review Date:** YYYY-MM-DD

### Summary
[Brief description of what was attempted and why it's blocked]

### Root Cause
[Technical explanation of the blocker]

### What Would Unblock This
[Upstream changes, external dependencies, or future conditions]

### Commits Related to This Work
[Git commit hashes and descriptions]
```
