# Documentation

Documentation for the home lab Kubernetes cluster (3× Lenovo ThinkCentre M900, Talos Linux).

## Architecture

### Stack

| Layer | Technology |
|-------|-----------|
| OS | Talos Linux (immutable, API-driven) |
| Kubernetes | v1.37.2 |
| GitOps | Argo CD — reconciles `kubernetes/` from git |
| Secrets | HashiCorp Vault + External Secrets Operator |
| Networking | Envoy Gateway, Cloudflare Tunnel, Cilium |
| Storage | Longhorn (block), SeaweedFS (S3), NFS |
| Backups | Kopiur → SeaweedFS (local) + Cloudflare R2 (offsite mirror) |
| Upgrades | Tuppr (Talos/K8s), Renovate (images/charts) |

### Secret Management

All credentials live in Vault (`secret-kv2/`). External Secrets Operator syncs them into Kubernetes Secrets. Only one SOPS-encrypted file remains in the repo: `vault-kms.sops.yaml` (AWS KMS key to unseal Vault on startup).

```
Vault (KV v2)
    ↓  External Secrets Operator (ClusterSecretStore)
Kubernetes Secrets  ←→  Applications
```

See [Secret Management](./SECRET_MANAGEMENT.md) for full details.

### Backup Strategy

```
PVC data
  ↓  Kopiur (Kopia snapshots, daily)
  ├── SeaweedFS S3 (in-cluster, primary repository)
  └── Cloudflare R2 (offsite, repository mirror)
```

- **22 PVCs** backed up across all namespaces
- Retention per app: 5 latest, 7 daily, 4 weekly, 3 monthly restore points
- R2 mirrors each namespace repository; `deleteExtra: true` keeps its object prefix aligned with SeaweedFS
- Credentials stored in Vault (`secret-kv2/kopiur/`)

## Guides

### Operations

- **[Maintenance Procedures](./MAINTENANCE.md)** — Routine checklists, upgrade procedures
- **[Troubleshooting Guide](./TROUBLESHOOTING.md)** — Symptom-driven diagnostics
- **[Disaster Recovery](./disaster-recovery.md)** — Full cluster rebuild procedures
- **[Secret Management](./SECRET_MANAGEMENT.md)** — Vault, ESO, SOPS bootstrap

### Infrastructure

- **[Resource Tiers](./resource-tiers.md)** — CPU/memory allocation guidelines
- **[Pod Security Standards](./pod-security-standards.md)** — Security policies per namespace
- **[Automated Upgrades (Tuppr)](./tuppr-upgrades.md)** — Talos and Kubernetes upgrade automation

### Backup & Recovery

- **[Volsync Deployment Guide](./volsync-deployment-guide.md)** — Adding PVC backups
- **[Volsync Restore Procedures](./volsync-restore-procedures.md)** — Restoring from backup

## Quick Reference

```bash
# Check all app health
kubectl get applications -n argo-system
just ops status

# Force Argo CD resync
just reconcile

# Check backup status
just ops backup-status
kubectl get replicationsource -A

# Validate cluster rendering (CI equivalent)
./scripts/argo-parity.sh --render-only --skip-app vault

# Vault status
kubectl -n vault exec vault-0 -- vault status
```
