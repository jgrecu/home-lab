# Secret Management Guide

**Last Updated:** 2026-11-13
**Applies To:** Production Kubernetes homelab with Argo CD GitOps

---

## Overview

This repository uses a **hybrid secret management** approach:

- **App secrets** (passwords, API keys, tokens) are stored in **Vault** (KV v2) and synced into Kubernetes Secrets by the **External Secrets Operator (ESO)**.
- **Bootstrap and infrastructure secrets** (needed before Vault/ESO exist) remain **SOPS-encrypted** in git.

---

## Architecture

### App Secrets — Vault + ESO (primary path)

```
┌─────────────────────────────────────────────────────────────────┐
│  Vault (secret-kv2/)                                            │
│  vault kv put secret-kv2/<app> key=value ...                    │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼ Kubernetes auth (ESO ServiceAccount)
┌─────────────────────────────────────────────────────────────────┐
│  External Secrets Operator                                      │
│  ClusterSecretStore "vault" → http://vault-active.vault.svc     │
│  ExternalSecret per app (refreshInterval: 1h)                   │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Secret (owned by ExternalSecret)                    │
│  Mounted into pods as environment variables or files            │
└─────────────────────────────────────────────────────────────────┘
```

### Bootstrap Secret — SOPS (1 file only)

```
vault-kms.sops.yaml  (AWS KMS credentials — git-encrypted)
    ↓  decrypted by Argo CD ksops at startup
Vault auto-unseals
    ↓  External Secrets Operator (ClusterSecretStore "vault")
Kubernetes Secrets  ←→  Applications
```

The age private key (`bootstrap/sops-age.sops.yaml`) is used only during initial cluster
bootstrap to provision the in-cluster `sops-age` Secret that Argo CD needs to decrypt
`vault-kms.sops.yaml` on every sync.

---

## What Lives Where

### In Vault (ESO-managed)

All app secrets — written once with `vault kv put`, never in git:

| Vault path | Kubernetes Secret | App |
|---|---|---|
| `secret-kv2/linkding` | `linkding-secret` | linkding |
| `secret-kv2/nextcloud` | `nextcloud-secret` | nextcloud |
| `secret-kv2/bazarr` | `bazarr-secret` | bazarr |
| `secret-kv2/lingarr` | `lingarr-secret` | lingarr |
| `secret-kv2/prowlarr` | `prowlarr-secret` | prowlarr |
| `secret-kv2/radarr` | `radarr-secret` | radarr |
| `secret-kv2/sonarr` | `sonarr-secret` | sonarr |
| `secret-kv2/recyclarr` | `recyclarr-secret` | recyclarr |
| `secret-kv2/grimmory` | `grimmory-mariadb-secret` | grimmory |
| `secret-kv2/pihole` | `pihole-secret` | pihole |
| `secret-kv2/wg-portal` | `wg-portal-secret` | wg-portal |
| `secret-kv2/grafana` | `grafana-secret` | grafana |
| `secret-kv2/s3manager` | `s3manager-secret` | s3manager |
| `secret-kv2/forgejo` | `forgejo-secret` | forgejo |
| `secret-kv2/forgejo-runner` | `forgejo-runner-secret` | forgejo-runner |
| `secret-kv2/woodpecker` | `woodpecker-server-secret` | woodpecker-server |
| `secret-kv2/woodpecker-agent` | `woodpecker-agent-secret` | woodpecker-agent |
| `secret-kv2/health-auto-export` | `health-auto-export-secret` | health-auto-export |
| `secret-kv2/health-auto-export-mongodb` | `health-auto-export-mongodb-secret` | health-auto-export-mongodb |
| `secret-kv2/immich-exporter` | `immich-exporter` | immich |

### Stays SOPS (bootstrap only — 1 file)

| File | Secret | Why |
|------|--------|-----|
| `vault/vault/config/vault-kms.sops.yaml` | AWS KMS credentials | Needed to unseal Vault — cannot bootstrap from Vault |

All other secrets are in Vault. The age key (`bootstrap/sops-age.sops.yaml`) is used only during initial cluster bootstrap.

---

## Adding a New App Secret

### Step 1 — Write to Vault

```bash
vault kv put secret-kv2/<app> \
  key1=value1 \
  key2=value2
```

### Step 2 — Create ExternalSecret

Create `kubernetes/apps/<namespace>/<app>/config/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <app>-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: <app>-secret
    creationPolicy: Owner
  data:
    - secretKey: key1
      remoteRef:
        key: <app>
        property: key1
    - secretKey: key2
      remoteRef:
        key: <app>
        property: key2
```

In `kubernetes/apps/<namespace>/<app>/config/kustomization.yaml`, add `externalsecret.yaml` to `resources:` (do not use `generators:`).

### Step 4 — Reference secret in Helm values

```yaml
# values.yaml
env:
  MY_KEY:
    valueFrom:
      secretKeyRef:
        name: <app>-secret
        key: key1
```

### Step 5 — Commit and push

```bash
git add kubernetes/apps/<namespace>/<app>/config/
git commit -m "feat(<app>): add ESO ExternalSecret"
git push
```

### Step 6 — Verify

```bash
kubectl -n <namespace> get externalsecret <app>-secret
# STATUS should be SecretSynced / READY True
```

---

## Rotating an App Secret

```bash
# 1. Update the value in Vault
vault kv patch secret-kv2/<app> key1=new-value

# 2. Force immediate ESO refresh (optional — auto-refreshes within 1h)
kubectl -n <namespace> annotate externalsecret <app>-secret \
  force-sync=$(date +%s) --overwrite

# 3. Restart the pod to pick up the new Secret
kubectl -n <namespace> rollout restart deployment <app>
```

---

## Rotating a Bootstrap (SOPS) Secret

The only SOPS-encrypted secret is `kubernetes/apps/vault/vault/config/vault-kms.sops.yaml`
(AWS KMS credentials for Vault auto-unseal). Edit it directly with `sops`:

```bash
# 1. Edit in-place (sops decrypts, opens $EDITOR, re-encrypts on save)
sops kubernetes/apps/vault/vault/config/vault-kms.sops.yaml

# 2. Verify the file is still encrypted
sops filestatus kubernetes/apps/vault/vault/config/vault-kms.sops.yaml

# 3. Commit
git add kubernetes/apps/vault/vault/config/vault-kms.sops.yaml
git commit -m "security(vault): rotate AWS KMS credentials"
git push
```

---

## ESO Infrastructure

| Resource | Details |
|---|---|
| Namespace | `external-secrets` |
| Chart | `ghcr.io/external-secrets/charts/external-secrets` |
| Argo Application | `kubernetes/argo/apps/vault/external-secrets.yaml` (wave 3) |
| ClusterSecretStore | `vault` → `http://vault-active.vault.svc:8200` KV v2 |
| Vault auth role | `external-secrets` (bound to `external-secrets` ServiceAccount) |
| Vault policy | `eso-read` (`secret-kv2/data/*` read, `secret-kv2/metadata/*` list+read) |
| Refresh interval | 1h per ExternalSecret |
| Alerts | `ExternalSecretSyncError`, `ExternalSecretNotReady` (PrometheusRule) |

---

## SOPS Configuration

**`.sops.yaml`** (repo root) defines three encryption rules:
- Talos machine configs: `mac_only_encrypted`
# (removed — values files are now plain YAML; only vault-kms.sops.yaml uses SOPS)
- All other `*.sops.yaml`: `encrypted_regex: ^(data|stringData|spec|metadata)$`

**Age public key:** `age1vmuwa3m333fmewnm9ltl02qg9sa6675qe4459cctyt7mjcfz6a0q5j4fxt`
**Age private key:** `age.key` (gitignored — back up securely offline)

---

## Troubleshooting

### ExternalSecret not syncing

```bash
# Check status and last sync error
kubectl -n <namespace> describe externalsecret <name>

# Check ClusterSecretStore is Ready
kubectl get clustersecretstore vault

# Check ESO pods are running
kubectl -n external-secrets get pods
```

### SOPS decryption failed (bootstrap secrets)

```bash
# Compare the cluster age key with the local one (no output = identical)
diff <(kubectl -n argo-system get secret sops-age \
  -o jsonpath='{.data.age\.agekey}' | base64 -d) age.key

# Fix: re-apply the SOPS age secret
sops exec-file bootstrap/sops-age.sops.yaml \
  'kubectl -n argo-system apply --server-side -f {}'

# Restart repo-server
kubectl -n argo-system rollout restart deployment argocd-repo-server
```

### Secret not updating in pod after Vault change

```bash
# Force ESO to re-sync immediately
kubectl -n <namespace> annotate externalsecret <name> \
  force-sync=$(date +%s) --overwrite

# Restart pod
kubectl -n <namespace> rollout restart deployment <app>
```

---

## Secret Rotation Schedule

| Secret Type | Frequency | Location |
|---|---|---|
| App API keys (arr stack) | Every 90 days | Vault |
| App passwords | Every 180 days | Vault |
| OAuth secrets (Woodpecker) | After team changes | Vault |
| Cloudflare token | Every 180 days | Vault |
| WireGuard private key | On compromise only | Vault |
| Volsync restic password | Every 365 days | Vault |
| age private key | On compromise only | `age.key` (offline backup) |

---

**Last Reviewed:** 2026-11-11
**Next Review:** 2026-02-11
