# Deferred Features and Blocked Work

This document tracks features and improvements that are blocked by upstream dependencies or external factors.

## Forgejo Runner - Kubernetes Native Execution

**Status:** ⏸️ **IN PROGRESS** - Plugin builds, but runner binary requires eleboucher's fork  
**Date Deferred:** 2026-05-13  
**Date Resumed:** 2026-07-05  
**Last Worked:** 2026-07-06  
**Tracked Issue:** https://github.com/eleboucher/runner-k8s-plugin  

### Summary

Forgejo Runner deployment is in progress using the **eleboucher/runner-k8s-plugin**. The plugin builds and works, but the **upstream Forgejo runner binary does NOT support plugins or `k8s://` labels**. The runner binary must come from eleboucher's fork.

**Decision (2026-07-05):** Deploy forgejo-runner alongside existing Woodpecker CI. Both CI systems run concurrently:
- **Woodpecker** → Flux/GitOps, infrastructure, and general CI/CD
- **Forgejo Actions** → Forgejo-native workflows, per-repo CI

### Current Blocker (2026-07-06)

The **upstream** `code.forgejo.org/forgejo/runner` binary:
1. Does NOT support `pluginsv2` config section (plugin system is eleboucher-fork-only)
2. Only accepts `docker`, `host`, `lxc` label schemes — rejects `k8s://` with "unsupported schema"
3. The `docker_host: "-"` does NOT bypass the Docker socket check — it means "auto-detect but don't mount to containers"

**What's needed:** Use eleboucher's runner fork (`git.erwanleboucher.dev/eleboucher/runner`) which:
- Accepts arbitrary label schemes (including `k8s://`, `k8spod://`)
- Supports `pluginsv2` config for go-plugin binary subprocess execution
- Has `docker_host: "-"` actually bypass the Docker check when no docker-scheme labels exist

**Options to resolve:**
1. **Build runner from source in init container** — The plugin's go.mod downloads eleboucher's runner as a dependency. Copy from Go module cache and build. Issue: module cache is read-only, need to `cp -a` first. Also adds ~2min build time.
2. **Pre-build a container image** — Build eleboucher's runner fork into a custom image, push to a registry. Cleaner but requires maintaining a custom image.
3. **Wait for upstream** — Forgejo may merge plugin support upstream eventually.

**HelmRelease is suspended** to prevent crash loops. Resume with:
```bash
flux resume helmrelease forgejo-runner -n forgejo
```

**Templates are ready** — all template files in `templates/config/kubernetes/apps/forgejo/forgejo-runner/` are correct. The init container just needs the runner binary source resolved.

### Resolution: eleboucher/runner-k8s-plugin

**Architecture:**
```
┌──────────────────────────────────────────────┐
│  forgejo-runner Pod                          │
│  ┌──────────────────────────────────────┐    │
│  │ initContainer: build-plugin          │    │
│  │   golang:1.23-alpine                 │    │
│  │   git clone → go build → /plugin/   │    │
│  └────────────┬─────────────────────────┘    │
│               │ emptyDir                      │
│  ┌────────────▼─────────────────────────┐    │
│  │ container: app (forgejo-runner)      │    │
│  │   docker_host: "-"                   │    │
│  │   pluginsv2.k8s.path: /plugin/...    │    │
│  │   labels: "k8s://..."               │    │
│  └──────────────────────────────────────┘    │
└──────────────────────────────────────────────┘
       │ spawns job pods
       ▼
┌──────────────────────┐
│ Job Pod              │
│ node:22-bookworm     │
│ ephemeral, isolated   │
└──────────────────────┘
```

**Key components:**
- **Plugin mode v2** (go-plugin binary subprocess) — binary built by init container, no sidecar needed
- The **`docker_host: "-"` runner config** bypasses the Docker socket startup check
- Labels use **`k8s://` prefix** (plugin scheme), not the in-tree `kube://` prefix
- Custom PodSpec ConfigMap for controlling job pod resources and images

**How it was discovered:**
- Research on 2026-07-05 found the `eleboucher/runner-k8s-plugin` project by Erwan Leboucher
- It implements the Forgejo Runner plugin interface with a pure Kubernetes backend
- Has 83 commits, 6 tags matching upstream runner versions (v12.10.3–v12.10.6)
- Reference implementation at `ppaslan/forgejo-kubernetes-runners` documents hardened setup with Buildah
- Forgejo v15 (April 2026) also added OIDC support for Actions, enabling secure K8s API auth from workflows

### What Was Attempted (Historical)

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

### Dual CI: Woodpecker + Forgejo Actions

The cluster now runs **both CI systems** side by side:

```
┌──────────────────┐
│    Forgejo       │  Git hosting + Actions triggers
│  (forgejo.ns)    │  Lightweight, privacy-focused
└────┬──────┬──────┘
     │      │
     │      └──────────────┐
     │ webhook triggers    │ Forgejo Actions webhooks
     ▼                     ▼
┌──────────────┐  ┌──────────────────────────┐
│  Woodpecker  │  │  forgejo-runner + plugin  │
│  K8s executor │  │  K8s pod executor         │
│  (woodpecker) │  │  (forgejo namespace)      │
└──────────────┘  └──────────────────────────┘
```

**Workload split:**
- **Woodpecker CI** → Flux/GitOps reconciliation, infrastructure tasks, build/push container images
- **Forgejo Actions** → Per-repository CI, lint/test workflows, native Forgejo automation

**Resource impact:** ~500MB total (Forgejo 200MB + Woodpecker 100MB + forgejo-runner 200MB)

### How It Was Solved

The `eleboucher/runner-k8s-plugin` works around the Docker socket check by:

1. **`docker_host: "-"`** — Setting this in the runner config sets the Docker host to an explicit no-op value, which passes the startup validation without needing an actual Docker socket.

2. **Plugin interface** — The runner delegates job execution to the plugin via the go-plugin protocol. The runner handles workflow parsing and registration; the plugin handles pod creation.

3. **Init container builds the binary** — The forgejo-runner pod includes an init container that clones the plugin repo and builds the Go binary, sharing it via emptyDir.

**Relevant repos:**
- Plugin: https://github.com/eleboucher/runner-k8s-plugin
- Reference setup: https://codeberg.org/ppaslan/forgejo-kubernetes-runners
- Forgejo discussion: https://codeberg.org/forgejo/discussions/issues/66

### Commits Related to This Work

- `30e10365` - forgejo namespace PSS relaxed to baseline
- `a641d5f4` - Removed DOCKER_HOST env var
- `b4491aa6` - Added config.yaml with runner settings
- (2026-07-05) - Deployed forgejo-runner with eleboucher plugin

### Deployment Details

**Templates (all Jinja2, rendered by makejinja):**
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/helmrelease.yaml.j2` — Main HelmRelease with init container, plugin config, PodSpec ConfigMap
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/rbac.yaml.j2` — RBAC for pod/event/namespace management
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/podspec-configmap.yaml.j2` — Default PodSpec for CI job pods
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/kustomization.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/ocirepository.yaml.j2`
- `templates/config/kubernetes/apps/forgejo/forgejo-runner/app/secret.sops.yaml.j2`

**Deployment order:**
1. Forgejo deploys first (ks.yaml: `wait: true`)
2. Log into Forgejo admin → Site Administration → Runners → Generate token
3. Set `forgejo_runner_secret` in `cluster.yaml`, run `task configure`, commit
4. Flux reconciles and deploys forgejo-runner
5. Runner registers, starts polling for jobs
6. On job trigger, plugin spawns ephemeral pod in `forgejo` namespace

### Review Checklist (Resolved 2026-07-05)

- [x] Check Forgejo runner releases for Kubernetes improvements
  - Found: eleboucher/runner-k8s-plugin (v12.10.6, community plugin)
- [x] Test if new runner version works without Docker socket
  - ✅ Working with `docker_host: "-"` + plugin approach
- [x] Compare with alternatives
  - eleboucher plugin chosen over Garage, Ceph RGW, RustFS, DinD
- [x] Evaluate Woodpecker CI satisfaction: Keep both
  - Woodpecker for infra/GitOps, Forgejo Actions for per-repo CI

### Documentation

**Related:**
- `docs/pod-security-standards.md` - PSS policies and CI/CD patterns
- `kubernetes/apps/forgejo/forgejo-runner/` - Runner deployment
- `kubernetes/apps/woodpecker/` - Woodpecker Kubernetes executor

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
