# RustFS vs SeaweedFS — Migration Analysis

**Date:** 2026-09-18
**Status:** Deferred — revisit Q1 2027
**Decision:** Stay on SeaweedFS for now

---

## Context

This analysis was prompted by RustFS 1.0.0 GA releasing on 2026-09-16. The question was whether
to replace SeaweedFS with RustFS as the cluster's S3-compatible object storage backend.

### Current SeaweedFS Role

| Aspect | Detail |
|--------|--------|
| Architecture | `master` (metadata) + `volume` (data) + `filer` (S3 gateway) |
| Storage backend | NFS-mounted from NAS (`/seaweedfs`), not cluster-local |
| Replication | `000` — no internal redundancy; durability delegated to NAS |
| S3 buckets | `volsync-backups`, `cnpg-backups`, `longhorn-backups` |
| Consumers | Volsync (18 apps), CloudNativePG (4 clusters), Longhorn snapshots |
| Key property | Data survives complete cluster destruction — outlives Kubernetes |

---

## What RustFS Is

RustFS is a MinIO-compatible, S3-compatible object storage system written in Rust, licensed under
Apache 2.0. It is positioned as a drop-in replacement for MinIO, not SeaweedFS.

- Single binary (vs SeaweedFS's 3-component stack)
- Erasure coding for data durability (designed for direct-attached storage)
- Built-in web console, IAM, versioning, object lock, lifecycle management, OIDC/SSO
- MinIO tooling ecosystem (`mc`, `rclone`) works natively
- 32.9k GitHub stars; 1.0.0 GA shipped 2026-09-16

---

## Pros of Switching

**Simpler architecture**
Single binary replaces 3 coordinated SeaweedFS components (master + volume + filer), each with
their own PVCs, resource tuning, and independent failure modes. Helm values and bootstrap
complexity drop significantly.

**Better S3 compatibility**
RustFS is purpose-built as a MinIO-compatible S3 layer. SeaweedFS's S3 is implemented on top of
its filer abstraction — occasional quirks exist around multipart uploads and lifecycle APIs.

**Built-in web console**
Currently a separate `cloudlena/s3manager` container provides the UI. RustFS ships a full
management console on port 9001 — one fewer container to maintain.

**Richer feature set**
IAM/policies, versioning, object lock (WORM), lifecycle management (ILM), S3 event notifications,
audit logging, and OIDC/SSO are all first-class in RustFS. SeaweedFS has equivalents but they are
less polished.

**Memory safety**
SeaweedFS is Go (GC pauses, memory safety by convention). RustFS is Rust — deterministic memory,
no GC, no data races. Meaningful for storage software handling critical backup data.

**Native Prometheus metrics**
RustFS ships MinIO-compatible metrics. Existing Grafana dashboards from the MinIO ecosystem work
out of the box, replacing the 3 separate SeaweedFS ServiceMonitors.

---

## Cons / Risks

**RustFS is very new**
1.0.0 GA released 2026-09-16 — 2 days before this analysis. Post-GA edge cases will surface over
the coming months. Adopting it immediately for a system storing PostgreSQL WAL archives and daily
PVC backups is premature.

**Architecture mismatch: RustFS is designed for DAS, not NFS**
The most important architectural decision in the current SeaweedFS setup is the NFS backend — all
data lives on the NAS and survives a complete cluster rebuild. RustFS (like MinIO) is designed
and optimized for direct-attached storage with erasure coding. Running RustFS on an NFS-mounted
volume eliminates all erasure coding benefits and is an untested, undocumented deployment pattern.
This would undermine a deliberate and well-tested homelab design decision.

**Incompatible data formats — full migration required**
SeaweedFS uses its own internal volume format. RustFS uses a MinIO-compatible on-disk format.
There is no in-place migration. The process would be:

1. Deploy RustFS alongside SeaweedFS
2. Copy all S3 data using `mc mirror` or `rclone`
3. Re-point all consumers (Volsync secrets, CNPG backup secrets, Longhorn backup target)
4. Validate WAL archives and Restic snapshots are intact
5. Decommission SeaweedFS

All data is re-creatable (Volsync can re-backup, CNPG can re-archive WAL), but this is
significant effort with no functional upside at homelab backup-workload scale.

**Bootstrap script needs full rewrite**
`scripts/bootstrap-seaweedfs.sh` uses `weed shell` for bucket creation and S3 auth. RustFS uses
`mc` or the REST admin API. The entire bootstrap flow — bucket creation, credential injection,
`cluster.yaml` patching — must be rewritten.

**Loss of the NFS disaster-recovery property**
With SeaweedFS: destroy the cluster, reinstall, run `task storage:bootstrap-seaweedfs`, and all
backups are still present on the NAS. With RustFS on local/attached storage this property is gone
unless an NFS backend is explicitly re-implemented — which is not documented or tested.

**Helm chart maturity gap**
SeaweedFS Helm chart (v4.47.0) is battle-tested. RustFS's Helm chart will have rough edges in
the months immediately following 1.0.0 GA.

---

## Neutral Observations

| Factor | Assessment |
|--------|-----------|
| Performance | At homelab backup-workload scale (a few GB/day), irrelevant |
| S3 consumers | Volsync/Restic, CNPG, Longhorn are all S3-standard — work with either |
| License | Both Apache 2.0 — no difference |
| ARM64 support | Both support `linux/arm64` (RPi4 nodes) |
| Resource usage | RustFS single binary likely lower overhead than 3 SeaweedFS pods |

---

## Decision: Stay on SeaweedFS

The NFS-backed architecture is a deliberate design choice that gives this cluster a disaster
recovery property that RustFS cannot easily replicate. Combined with RustFS being brand-new at
GA, the risk/reward ratio does not favour migration at this time.

---

## Revisit Criteria (Q1 2027)

Reconsider when **all** of the following are true:

- [ ] RustFS has at least 3-6 months of post-GA production hardening
- [ ] RustFS documents and supports NFS-backed single-node deployments
- [ ] A Helm chart with stability comparable to SeaweedFS v4.x exists
- [ ] A tested `mc mirror` migration runbook is available from the community

If RustFS does not support NFS backends by Q1 2027, the alternative worth evaluating is keeping
SeaweedFS and simplifying its configuration (e.g., reducing resource reservations, consolidating
the bootstrap script).

---

## References

- RustFS GitHub: https://github.com/rustfs/rustfs
- RustFS 1.0.0 GA announcement: https://rustfs.com/blog/announcing-rustfs-1-0-0-ga/
- RustFS Helm chart: https://charts.rustfs.com/
- SeaweedFS Helm chart: https://seaweedfs.github.io/seaweedfs/helm
- Current SeaweedFS deploy: `templates/config/kubernetes/apps/storage/seaweedfs/`
- Bootstrap script: `scripts/bootstrap-seaweedfs.sh`
