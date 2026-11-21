# Immich PostgreSQL 16 to 18 Migration Plan

**Prepared:** 2026-11-21

**Status:** Research and read-only preflight complete; execution not approved

**Scope:** `entertainment/immich-postgres`, managed by CloudNativePG (CNPG)

## Decision

Rehearse a logical migration into a **separate PostgreSQL 18 CNPG cluster**, then perform a controlled endpoint cutover during a maintenance window. Keep the existing PG16 cluster and its backups intact.

The database is small, spare storage is available, and this approach avoids the custom-image runtime and destructive rollback constraints of an in-place upgrade. Keep the Immich application, Helm chart, operator, and VectorChord versions unchanged where possible. Do not combine this migration with a backup-plugin migration.

This document authorizes nothing beyond planning. Creating a rehearsal cluster, taking backups, changing access rules, stopping writers, committing/pushing manifests, cutting over, and deleting retained resources require separate approval. No production configuration was changed during this research.

## Verified Baseline

Findings were collected on 2026-11-21. Refresh them before execution; image aliases, capacity, backup age, and cluster state can change.

| Item | Observed value |
| --- | --- |
| Immich / Helm chart | `v3.4.2` / `0.13.4` |
| CNPG operator | `1.30.2` |
| PostgreSQL | `16.14`, Debian 12 / Bookworm, amd64 |
| Source image alias | `ghcr.io/tensorchord/cloudnative-vectorchord:16-1.1.1` |
| Running image digest, both instances | `sha256:4a26ca6aad2482289f4a3d3317ccbf1439ce3de140994598375a1f4c4e2e9f8d` |
| Topology | One primary (`immich-postgres-1`) and one streaming replica |
| Database size | `191691799` bytes, approximately 183 MiB |
| Database encoding / locale | UTF8 / `C` |
| Checksums | Off on PG16; decide explicitly for the new cluster |
| Extension preload | `vchord.so` |
| Application role | `immich`, non-superuser, no CREATE DATABASE or CREATE ROLE privilege |
| Storage | Two 10 GiB PVCs, `longhorn-single`, one Longhorn replica per PVC |
| Primary filesystem | Approximately 783 MiB used, 9 GiB available |
| WAL directory | Approximately 576 MiB |
| Longhorn reported actual size | Approximately 2.7 GiB per database volume; not the same measure as filesystem usage |
| Replication / local WAL | Zero replay gap and zero unflushed bytes at inspection |
| Backup tooling | Barman `3.19.1`, boto3 `1.43.36` |

### Installed extensions

| Extension | Version |
| --- | --- |
| `vchord` | `1.1.1` |
| `vector` | `0.8.3` |
| `cube` | `1.5` |
| `earthdistance` | `1.2` |
| `pg_trgm` | `1.6` |
| `unaccent` | `1.1` |
| `uuid-ossp` | `1.1` |
| `plpgsql` | `1.0` |

Both `face_index` and `clip_index` exist. Their observed sizes were approximately 704 KiB and 1104 KiB, respectively. Validate all database objects, not just these two indexes.

### Backup and asset protection

- CNPG archives to `s3://cnpg-backups/immich-postgres/`, with server name `immich-postgres`, through the SeaweedFS filer.
- Weekly base backups run Mondays at 02:00 UTC. All 13 listed Backup resources reported `completed`; the latest completed backup was 2026-11-16 at 02:00:10 UTC.
- Configured retention is `180d`. The ScheduledBackup comment saying four weekly backups is not the effective retention policy.
- Archiving and cluster conditions were healthy. The single recorded archive failure was on November 15, followed by successful archives.
- No restore rehearsal was performed. A completed backup resource is not proof that recovery works.
- Photos and videos are on the NFS export `192.168.1.37:/immich`, bound through `immich-library`. Independent NAS backup/snapshot coverage and restore evidence remain unverified.
- Database backups do not include photo/video files. Immich's non-superuser role means its built-in backups must not be assumed to work; the documented `pg_dumpall` backup path requires superuser permission.
- WAL archival age alone, including the Grafana label "Unsynced", does not establish replication failure. Idle periods can produce long intervals between successful archives.

### Storage headroom

Longhorn uses 100% overprovisioning, a 25% minimum-free setting, and approximately 20% disk reservation. All inspected nodes and disks were ready and schedulable.

| Node | Physical free GiB | Free above 25% floor, GiB | Unallocated capacity after reservation, GiB |
| --- | ---: | ---: | ---: |
| `m900-ctrl` | 187.2 | 68.6 | 48.9 |
| `m900-wrk1` | 138.9 | 20.2 | 200.3 |
| `m920x-wrk2` | 160.0 | 41.3 | 103.8 |

These are separate capacity checks, not interchangeable guarantees. A second two-instance cluster with the same storage class requests another **20 GiB** of PVC capacity, plus images and temporary working space. CNPG logical import stores its temporary dump on the destination PGDATA volume; allow for the dump, restored tables/indexes, WAL, and working headroom. Recheck disk and node CPU/memory capacity before scheduling.

## Compatibility and Image Selection

Immich's v3.4.2 tagged documentation confirms:

- PostgreSQL `>=14, <20`, including PG18.
- VectorChord `>=0.3, <2.0`, including the existing `1.1.1`.
- pgvector `>=0.7, <0.9` when used with VectorChord, including the source `0.8.3`.
- `vchord.so` must be preloaded. Keep pgvector installed because VectorChord depends on its types.

The following candidate was verified in GHCR, including amd64/arm64 manifests:

```text
ghcr.io/tensorchord/cloudnative-vectorchord:18.6-1.1.1
sha256:c7672bc011351a587cc292a94aac7eeebb593ed2e120077bd9c9944c9467db93
```

The floating `18-1.1.1` alias resolved to the same image. The exact `18.7-1.1.1` tag returned 404, while PostgreSQL documentation identified 18.7 as the current PG18 patch. Therefore, **18.6 is a verified rehearsal candidate, not a final production image decision**. Recheck availability and relevant security fixes before choosing a production target; obtain an updated image or separately review a reproducible CNPG-compatible derivative if needed. Pin the chosen image by digest.

The published candidate uses CNPG's Bookworm image family and includes PG18-specific VectorChord and pgvector packages. Its exact installed pgvector version, availability of every required extension, runtime behavior, and Barman/SeaweedFS backup compatibility have not been tested in a running target instance.

Do not infer extension versions from the image tag. Record `pg_available_extensions`, installed SQL versions, packaged backup tools, and the actual target digest during rehearsal.

## Safety and Approval Gates

Before any production migration, require:

- [ ] Approved target image, digest, PostgreSQL patch level, and compatible extension versions.
- [ ] Fresh successful PG16 base backup and verified PG16 restore into an isolated cluster.
- [ ] Verified independent backup of the NFS library, with recovery point and retention recorded.
- [ ] Successful PG18 logical restore, application validation, and PG18 backup/restore rehearsal.
- [ ] Recorded dump/import duration, free-space use, and agreed maintenance window. Do not promise downtime based solely on the 183 MiB database size.
- [ ] Agreed rollback deadline, acceptable recovery point, and decision owner.
- [ ] GitOps changes reviewed; automated reconciliation must not undo a writer freeze or prune the original cluster.
- [ ] Separate PG18 archive identity/path, preserving the PG16 archive.
- [ ] All source database writers identified and a durable stop/restart procedure prepared.

A PG16 physical backup cannot directly bootstrap PG18. Recover it using PG16, then upgrade or logically migrate. PITR does not cross the PostgreSQL major-version boundary.

## Phase 1: Prepare an Isolated Rehearsal

**Approval required:** target resources, credentials/access rules, backup/recovery operations, and test applications.

1. Refresh the baseline and record the selected source/target image digests, extension inventory, schema state, and capacity.
2. Use a distinct cluster name, such as `immich-postgres-18-rehearsal`, with new PVCs. Never repurpose the PG16 PVCs.
3. Retain `longhorn-single` and a two-instance topology unless a separately reviewed rehearsal profile is chosen. Decide encoding, locale, and checksums explicitly.
4. Provision credentials using Vault/External Secrets references. Do not put passwords in manifests, URLs in documentation, shell history, or logs. Limit network access to the required source/target/test components.
5. Restore a fresh PG16 physical backup into an isolated PG16 recovery cluster to prove the existing recovery path. Use the recorded source digest, not an unreviewed floating alias.
6. Prepare the PG18 destination and verify all required extension packages, control/SQL files, preload settings, and backup tools.
7. Review the logical-import mode and privileges. CNPG `microservice` import does not preserve roles/ACLs; configure the intended `immich` database owner and account for extension creation permissions. Do not blindly precreate schema objects that the dump will recreate.
8. Choose a tested CNPG import or controlled dump/restore path. Use PG18-compatible tooling and stop on restore errors; do not ignore missing extensions, permission errors, or failed index creation.

**Rehearsal isolation:** a test Immich application must not write to the production NFS library, share production Dragonfly queues, invoke external integrations, or accept production traffic. Use isolated queues and copied/snapshotted assets or deliberately read-only fixtures. Do not assume using a different database alone provides isolation.

## Phase 2: Rehearse and Validate

1. Import the PG16 data into PG18 and record timings and storage high-water marks. A rehearsal copy of a running source is not the final cutover copy.
2. Verify database ownership, grants, required extensions, schema migrations, row counts for relevant tables, sequences, and constraints.
3. Verify `face_index` and `clip_index` are present and usable. Keep VectorChord `1.1.1` where possible. If its SQL extension version changes, follow Immich's extension-update/reindex instructions in the rehearsal first.
4. Refresh optimizer statistics and review restore/extension warnings.
5. Start an isolated Immich `v3.4.2` instance against PG18. Confirm startup, login, albums, metadata, representative photo/video retrieval, semantic search, face search, and geolocation.
6. Confirm the new replica is ready and caught up, metrics scrape successfully, and there are no sustained database errors.
7. Configure a distinct PG18 archive location/server name. Test WAL upload, a fresh PG18 base backup, and restore into another isolated PG18 instance. Confirm retention behavior cannot remove PG16 recovery data.
8. Record the tested image/tool versions, evidence, restore procedure, and downtime estimate. Stop and request review on any failure.

**Exit criterion:** the exact image and migration procedure intended for production have passed the rehearsal. Testing one image and deploying a different digest requires renewed validation.

## Phase 3: Production Cutover

**Separate approval required:** maintenance window, durable writer freeze, final import, GitOps push, endpoint switch, and write-enable decision.

1. Refresh capacity, health, backups, and source/target versions. Confirm the original cluster and backup archive will remain protected from Argo CD pruning.
2. Freeze uploads and stop all Immich API/workers and other database writers through a reviewed procedure that GitOps will not immediately reverse. Machine-learning, exporters, and integrations should be evaluated by their actual behavior, not stopped indiscriminately.
3. Confirm no source writers remain. Take the agreed final database recovery points and consistent asset backup/snapshot. Preserve a fresh logical migration copy as well as the CNPG recovery backup.
4. Import the final frozen source into a fresh production PG18 destination, for example `immich-postgres-18`. Do not reuse stale rehearsal data as the production cutover copy.
5. Validate ownership, extensions, objects, selected row counts, indexes, replication, and backup configuration before allowing application access.
6. Change Immich's database endpoint and credential references through scoped, reviewed GitOps changes. Keep Immich `v3.4.2` and its existing application settings, including the IPv4 metrics-host fix.
7. Run controlled application validation while normal user traffic remains blocked. Any application startup or test that writes to PG18 must be tracked as part of the rollback boundary.
8. Have the decision owner explicitly approve enabling production writes. Observe application health, uploads, queues, search, metrics, replication, and logs.
9. Take a fresh PG18 base backup immediately after migration; do not wait for Monday. Verify continuous archiving to the separate PG18 archive.

Keep the PG16 cluster isolated from writers after cutover. Do not let both database versions serve different Immich writers concurrently.

## Rollback

### Before PG18 accepts writes

If validation fails and the PG16 source still represents the final frozen state, keep traffic blocked and stop the PG18 application. Revert the endpoint/credential references through GitOps, confirm only PG16 receives writers, validate the original database and application, then resume traffic with approval.

This rollback depends on retaining the original PG16 cluster/PVCs, configuration, credentials, and matching assets. Test the procedure during rehearsal.

### After PG18 accepts writes

An endpoint switch back to PG16 is **not a lossless rollback**: new uploads, metadata changes, and jobs can diverge from the frozen source. Stop writers and escalate for a reviewed recovery plan. Either repair PG18, or explicitly accept/reconcile post-cutover changes before returning to PG16. Do not automatically import a PG18 dump into PG16; backward compatibility is not guaranteed.

### In-place alternative

CNPG 1.30.2 supports a direct offline 16-to-18 upgrade when the image major changes. It stops all database pods, copies the old PostgreSQL installation from the source image into the upgrade job, and runs the target `pg_upgrade` with `--link` against the primary's storage. Replica PVC groups are deleted and recreated; successful cleanup removes old data directories.

This does not necessarily require a single image containing both PostgreSQL versions. It does require compatible OS/distribution images, usable old binaries and extension dependencies in the target runtime, compatible target extension files, sufficient working space, and a successful exact-image-pair rehearsal.

After successful in-place conversion, changing the image back is not a safe downgrade. Recover PG16 from its preserved backup into a PG16 cluster. Failure recovery must be investigated before reverting an image or terminating an active upgrade job. Do not substitute an untested in-place upgrade for the rehearsed blue/green plan.

## Post-Cutover and Cleanup

- [ ] Record deployed digests, extension versions, migration evidence, and backup/restore instructions.
- [ ] Confirm PG18 backup schedule and retention, including a newly completed base backup.
- [ ] Monitor for an agreed observation period and validate representative application operations.
- [ ] Preserve the original PG16 cluster, PVCs, and archive for an explicitly agreed rollback retention period.
- [ ] Obtain separate approval before removing the original cluster/PVCs/archive. Review `Retain` policies and Argo CD pruning behavior first.
- [ ] Review native Barman migration separately. `barmanObjectStore` is deprecated in CNPG 1.30.2; its versioned documentation identifies 1.31 as the last supporting minor and removal from 1.32. Revalidate this before any operator upgrade.

Do not apply Docker Compose PG18 volume-layout instructions to CNPG. CNPG manages its own `PGDATA` path; the Docker Official Image's new directory convention is not a universal PG18 storage requirement.

## Repository References

- [Immich database manifest](../kubernetes/apps/entertainment/immich/config/postgres.yaml)
- [Scheduled database backup](../kubernetes/apps/entertainment/immich/config/scheduledbackup.yaml)
- [NFS library volume](../kubernetes/apps/entertainment/immich/config/pvc.yaml)
- [Immich Helm values](../kubernetes/apps/entertainment/immich/values.yaml)
- [Argo CD application](../kubernetes/argo/apps/entertainment/immich.yaml)
- [Maintenance and GitOps conventions](./MAINTENANCE.md)

The legacy-looking Immich VolSync restore guidance is not a validated recovery procedure for the current CNPG cluster.

## External Sources

Research checked on 2026-11-21; recheck version-specific documentation before execution.

1. [Immich v3.4.2 standalone PostgreSQL guide](https://github.com/immich-app/immich/blob/v3.4.2/docs/docs/administration/postgres-standalone.md)
2. [Immich v3.4.2 compatibility constants](https://github.com/immich-app/immich/blob/v3.4.2/server/src/constants.ts)
3. [Current standalone PostgreSQL guide](https://docs.immich.app/administration/postgres-standalone/)
4. [Immich backup and restore guidance](https://docs.immich.app/administration/backup-and-restore)
5. [TensorChord CNPG image registry](https://github.com/tensorchord/cloudnative-vectorchord/pkgs/container/cloudnative-vectorchord)
6. [CNPG v1.30.2 PostgreSQL upgrades](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.2/docs/src/postgres_upgrades.md)
7. [CNPG v1.30.2 database import](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.2/docs/src/database_import.md)
8. [CNPG v1.30.2 native Barman integration](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.2/docs/src/appendixes/backup_barmanobjectstore.md)
9. [PostgreSQL 18 pg_upgrade, extensions, and rollback limitations](https://www.postgresql.org/docs/18/pgupgrade.html)
