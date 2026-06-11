# Secret Management Guide

**Last Updated:** 2026-06-11  
**Applies To:** Template-driven Kubernetes homelab with Flux GitOps

---

## Overview

This repository uses a **template-driven SOPS encryption pipeline** to manage all secrets. Secrets are defined in plaintext configuration files (gitignored), rendered through Jinja2 templates, encrypted with SOPS (age), and committed as encrypted YAML files that Flux can decrypt in-cluster.

---

## Architecture

### Secret Flow Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│  cluster.yaml (gitignored, plaintext)                           │
│  - All passwords, tokens, API keys defined here                 │
│  - Never committed to git                                       │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  templates/config/*/secret.sops.yaml.j2                         │
│  - Jinja2 templates reference cluster.yaml variables            │
│  - Pattern: "#{ variable_name }#"                               │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼ task configure --yes
┌─────────────────────────────────────────────────────────────────┐
│  makejinja (template rendering)                                 │
│  - Reads cluster.yaml + nodes.yaml                              │
│  - Renders 386+ templates into kubernetes/ manifests            │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼ SOPS encryption
┌─────────────────────────────────────────────────────────────────┐
│  kubernetes/apps/*/secret.sops.yaml (encrypted, committed)      │
│  - stringData fields encrypted with age                         │
│  - Metadata remains plaintext                                   │
│  - Safe to commit to public git repository                      │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼ git commit + push
┌─────────────────────────────────────────────────────────────────┐
│  GitHub (public repository)                                     │
│  - Only encrypted secrets stored                                │
│  - No plaintext secrets ever committed                          │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼ Flux reconciliation
┌─────────────────────────────────────────────────────────────────┐
│  Flux SOPS Decryption (in-cluster)                              │
│  - Flux has access to age private key                           │
│  - Decrypts secrets before applying to cluster                  │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Secrets (runtime only)                              │
│  - Mounted into pods as environment variables or files          │
│  - Never stored in plaintext on disk (etcd encryption optional) │
└─────────────────────────────────────────────────────────────────┘
```

---

## Security Controls

### ✅ Implemented

1. **Gitignored plaintext:** `cluster.yaml`, `nodes.yaml`, and `age.key` are in `.gitignore`
2. **Encryption at rest:** All secrets in git repository are SOPS-encrypted
3. **Age encryption:** Modern, simple encryption (not PGP)
4. **Encrypted regex:** Only `data` and `stringData` fields encrypted (metadata readable)
5. **Secret scoping:** Each app has its own Secret resource (least privilege)
6. **Template-driven:** Single source of truth (cluster.yaml) for all secrets

### 🔒 Additional Recommendations

1. **Backup age.key:** Store age private key in secure offline location
2. **Secret rotation:** Rotate secrets every 90-180 days
3. **Password complexity:** Use `openssl rand -base64 20` for strong passwords
4. **Audit trail:** Document rotations with conventional commits: `security(app): rotate API key`

---

## File Structure

### Gitignored Files (Never Commit)

```
/cluster.yaml                    # Plaintext configuration (secrets defined here)
/nodes.yaml                      # Node-specific configuration
/age.key                         # SOPS age private key (decrypt secrets)
```

### Template Files (Committed)

```
templates/config/kubernetes/apps/<namespace>/<app>/app/
├── helmrelease.yaml.j2          # Main app deployment
├── kustomization.yaml.j2        # Kustomize overlay
├── secret.sops.yaml.j2          # Secret template (references cluster.yaml)
└── servicemonitor.yaml.j2       # Prometheus monitoring
```

### Generated Files (Committed, Encrypted)

```
kubernetes/apps/<namespace>/<app>/app/
├── helmrelease.yaml             # Generated manifest
├── kustomization.yaml           # Generated kustomize
├── secret.sops.yaml             # ENCRYPTED secret (safe to commit)
└── servicemonitor.yaml          # Generated monitoring
```

---

## Secret Template Patterns

### Pattern 1: Simple Secret

**Template:** `templates/config/kubernetes/apps/observability/grafana/app/secret.sops.yaml.j2`

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
stringData:
  admin-user: admin
  admin-password: "#{ grafana_admin_password }#"
```

**cluster.yaml:**

```yaml
grafana_admin_password: "<generated-password>"
```

**Generated (encrypted):** `kubernetes/apps/observability/grafana/app/secret.sops.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
stringData:
  admin-user: admin
  admin-password: ENC[AES256_GCM,data:AxE...,iv:...,tag:...,type:str]
sops:
  age:
    - enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
      recipient: age1vmuwa3m333fmewnm9ltl02qg9sa6675qe4459cctyt7mjcfz6a0q5j4fxt
  encrypted_regex: ^(data|stringData)$
  version: 3.13.1
```

### Pattern 2: Multi-Field Secret

**Template:** `templates/config/kubernetes/apps/network/wg-easy/app/secret.sops.yaml.j2`

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: wg-easy-secret
stringData:
  admin-password: "#{ wg_easy_admin_password }#"
  server-private-key: "#{ wg_easy_server_private_key }#"
```

**cluster.yaml:**

```yaml
wg_easy_admin_password: "<generated-password>"
wg_easy_server_private_key: "<wireguard-private-key>"
```

### Pattern 3: Backup Secrets (Volsync)

**Template:** `templates/config/kubernetes/apps/downloads/radarr/backup/secret.sops.yaml.j2`

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: radarr-config-restic-secret
stringData:
  RESTIC_REPOSITORY: s3:http://seaweedfs-filer.storage.svc.cluster.local:8333/volsync-backups/radarr-config
  RESTIC_PASSWORD: "#{ volsync_restic_password }#"
  AWS_ACCESS_KEY_ID: "#{ volsync_s3_access_key }#"
  AWS_SECRET_ACCESS_KEY: "#{ volsync_s3_secret_key }#"
```

**cluster.yaml:**

```yaml
volsync_restic_password: "<restic-encryption-password>"
volsync_s3_access_key: "<s3-access-key>"
volsync_s3_secret_key: "<s3-secret-key>"
```

### Pattern 4: Secret Reference in HelmRelease

**Template:** `templates/config/kubernetes/apps/downloads/radarr/app/helmrelease.yaml.j2`

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: radarr
spec:
  values:
    controllers:
      radarr:
        containers:
          exportarr:
            env:
              PORT: "9707"
              URL: "http://localhost:7878"
              APIKEY:
                valueFrom:
                  secretKeyRef:
                    name: radarr-secret
                    key: api-key
              ENABLE_ADDITIONAL_METRICS: "true"
```

**Key Points:**
- ✅ Use `secretKeyRef` to reference encrypted secrets
- ❌ Never hardcode secrets directly in helmreleases
- ✅ Secret name matches the template: `radarr-secret`

---

## Adding a New Secret

### Step-by-Step Guide

**Example:** Adding a new app "myapp" that needs an API key

#### 1. Add secret to cluster.yaml

```bash
vi cluster.yaml
```

Add:

```yaml
# -- MyApp API key for external service integration
#    (REQUIRED for MyApp)
myapp_api_key: "<generate-with-openssl-rand>"
```

#### 2. Create secret template

```bash
vi templates/config/kubernetes/apps/default/myapp/app/secret.sops.yaml.j2
```

Content:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
stringData:
  api-key: "#{ myapp_api_key }#"
```

#### 3. Add secret to kustomization

```bash
vi templates/config/kubernetes/apps/default/myapp/app/kustomization.yaml.j2
```

Add to resources:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./secret.sops.yaml  # <-- Add this line
```

#### 4. Reference secret in helmrelease

```bash
vi templates/config/kubernetes/apps/default/myapp/app/helmrelease.yaml.j2
```

Add secret reference:

```yaml
spec:
  values:
    env:
      MYAPP_API_KEY:
        valueFrom:
          secretKeyRef:
            name: myapp-secret
            key: api-key
```

#### 5. Generate and commit

```bash
# Regenerate all manifests (includes SOPS encryption)
task configure --yes

# Verify encryption worked
cat kubernetes/apps/default/myapp/app/secret.sops.yaml | grep "ENC\["

# Commit encrypted secret
git add templates/config/kubernetes/apps/default/myapp/app/
git add kubernetes/apps/default/myapp/app/secret.sops.yaml
git commit -m "feat(myapp): add API key secret with SOPS encryption"
git push
```

---

## Rotating Secrets

### Rotation Procedure

**Example:** Rotating Grafana admin password

#### 1. Generate new password

```bash
NEW_PASSWORD=$(openssl rand -base64 20)
echo "New password: $NEW_PASSWORD"
```

#### 2. Update cluster.yaml

```bash
vi cluster.yaml
```

Replace old password:

```yaml
grafana_admin_password: "<new-password-here>"
```

#### 3. Regenerate manifests

```bash
task configure --yes
```

#### 4. Verify encryption

```bash
# Check that secret was re-encrypted
git diff kubernetes/apps/observability/grafana/app/secret.sops.yaml

# Should show different encrypted data block
```

#### 5. Commit and push

```bash
git add kubernetes/apps/observability/grafana/app/secret.sops.yaml
git commit -m "security(grafana): rotate admin password"
git push
```

#### 6. Wait for Flux reconciliation

```bash
# Force immediate sync
flux reconcile kustomization grafana --with-source

# Verify secret updated in cluster
kubectl get secret grafana-secret -n observability -o yaml | grep admin-password
```

#### 7. Update application

Some apps may cache secrets. Restart the pod:

```bash
kubectl rollout restart deployment grafana -n observability
```

---

## Secret Rotation Schedule

### Recommended Intervals

| Secret Type | Rotation Frequency | Examples |
|-------------|-------------------|----------|
| API Keys | Every 90 days | Radarr, Sonarr, Prowlarr, Bazarr, Cloudflare |
| Passwords | Every 180 days | Grafana, Pi-hole, WireGuard Easy |
| OAuth Secrets | After team changes | Forgejo, Woodpecker |
| Backup Encryption | Every 365 days | Volsync Restic password |
| S3 Credentials | After access events | SeaweedFS S3 keys |

### Rotation Tracking

Keep a rotation log in `docs/SECRET_ROTATION_LOG.md`:

```markdown
# Secret Rotation Log

| Date       | Secret                  | Reason              | Rotated By |
|------------|-------------------------|---------------------|------------|
| 2026-06-11 | *arr API keys (4)       | Security audit      | Jeremy     |
| 2026-06-11 | Pi-hole admin password  | Weak password       | Jeremy     |
| 2026-06-11 | WireGuard admin password| Weak password       | Jeremy     |
```

---

## SOPS Configuration

### .sops.yaml

Located at repository root:

```yaml
---
creation_rules:
  - path_regex: .*\.sops\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1vmuwa3m333fmewnm9ltl02qg9sa6675qe4459cctyt7mjcfz6a0q5j4fxt
```

**Key Components:**
- `path_regex`: Only encrypt files matching `*.sops.yaml` or `*.sops.yml`
- `encrypted_regex`: Only encrypt `data` and `stringData` fields (keep metadata readable)
- `age`: Public key for encryption (recipient)

### Age Key Management

**Public Key (in .sops.yaml):**
```
age1vmuwa3m333fmewnm9ltl02qg9sa6675qe4459cctyt7mjcfz6a0q5j4fxt
```

**Private Key (in age.key, gitignored):**
```
# CRITICAL: Never commit this file
# Backup securely offline
AGE-SECRET-KEY-1...
```

**Backup Procedure:**
1. Copy `age.key` to encrypted USB drive
2. Store USB drive in secure location (safe, vault)
3. Test recovery: decrypt a test secret with backup key

**Recovery Test:**
```bash
# Use backup key to decrypt
SOPS_AGE_KEY_FILE=/path/to/backup/age.key \
  sops -d kubernetes/apps/observability/grafana/app/secret.sops.yaml
```

---

## Common Patterns

### Pattern: Auto-Generated Secrets

Some secrets are generated by Python functions, not defined in cluster.yaml:

**Function:** `github_push_token()`

```python
# templates/scripts/plugins/github_push_token.py
def github_push_token():
    """Generate GitHub personal access token from environment or prompt"""
    return os.getenv("GITHUB_TOKEN") or prompt_for_token()
```

**Template:**

```yaml
stringData:
  token: "#{ github_push_token() }#"
```

### Pattern: Shared Secrets

Multiple apps share the same secret (e.g., Volsync backup credentials):

**cluster.yaml:**

```yaml
volsync_restic_password: "<shared-across-all-apps>"
volsync_s3_access_key: "<shared-s3-access-key>"
volsync_s3_secret_key: "<shared-s3-secret-key>"
```

**28 apps reference these:**
- `downloads/radarr/backup/secret.sops.yaml.j2`
- `downloads/sonarr/backup/secret.sops.yaml.j2`
- `entertainment/jellyfin/backup/secret.sops.yaml.j2`
- ... (25 more)

**Rotation Impact:** Rotating shared secrets requires coordinated rollout across all apps.

### Pattern: Conditional Secrets

Enable secrets only when feature flag is set:

```yaml
#% if cluster.volsync.enabled %#
---
apiVersion: v1
kind: Secret
metadata:
  name: myapp-backup-secret
stringData:
  RESTIC_PASSWORD: "#{ volsync_restic_password }#"
#% endif %#
```

---

## Troubleshooting

### Issue: SOPS Decryption Failed

**Symptom:**
```
Error: error decrypting secret: no decryption key found for recipient
```

**Diagnosis:**
```bash
# Check SOPS age key in cluster
kubectl get secret sops-age -n flux-system -o jsonpath='{.data.age\.agekey}' | base64 -d

# Compare with local age.key
cat age.key
```

**Fix:**
```bash
# Re-create SOPS age secret in cluster
cat age.key | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Flux kustomize-controller
kubectl rollout restart deployment kustomize-controller -n flux-system
```

### Issue: Secret Not Updating in Pod

**Symptom:** Changed secret in git, but pod still uses old value

**Diagnosis:**
```bash
# Check secret in cluster
kubectl get secret myapp-secret -n namespace -o yaml

# Check pod environment
kubectl exec -it myapp-pod -n namespace -- env | grep SECRET
```

**Fix:**
```bash
# Force Flux reconciliation
flux reconcile kustomization myapp --with-source

# Restart pod to pick up new secret
kubectl rollout restart deployment myapp -n namespace
```

### Issue: Template Variable Not Found

**Symptom:**
```
makejinja error: variable 'myapp_api_key' is undefined
```

**Diagnosis:**
```bash
# Check if variable exists in cluster.yaml
grep myapp_api_key cluster.yaml
```

**Fix:**
1. Add missing variable to `cluster.yaml`
2. Run `task configure --yes` again

### Issue: Secret Not Encrypted

**Symptom:** Secret committed but still plaintext

**Diagnosis:**
```bash
# Check if file matches SOPS pattern
ls kubernetes/apps/*/app/secret.sops.yaml

# Check .sops.yaml configuration
cat .sops.yaml
```

**Fix:**
1. Ensure filename ends with `.sops.yaml` (not just `.yaml`)
2. Run `task configure --yes` to re-encrypt
3. Verify encryption: `grep "ENC\[" kubernetes/apps/*/app/secret.sops.yaml`

---

## Security Best Practices

### ✅ DO

1. **Generate strong secrets:**
   ```bash
   openssl rand -base64 20   # Passwords (20+ chars)
   openssl rand -hex 32      # API keys (64 hex chars)
   ```

2. **Verify encryption before committing:**
   ```bash
   git diff kubernetes/ | grep -E "password|token|key" | grep -v "ENC\["
   # Should return nothing
   ```

3. **Rotate secrets regularly:**
   - Set calendar reminders for 90/180 day rotations
   - Document rotations in `SECRET_ROTATION_LOG.md`

4. **Backup age.key securely:**
   - Encrypted USB drive
   - Password manager (1Password, Bitwarden)
   - Hardware security key (YubiKey with age-plugin-yubikey)

5. **Use secret references in helmreleases:**
   ```yaml
   # ✅ Good
   env:
     API_KEY:
       valueFrom:
         secretKeyRef:
           name: myapp-secret
           key: api-key
   ```

### ❌ DON'T

1. **Never commit plaintext secrets:**
   ```bash
   # ❌ Bad - will leak in git history
   git add cluster.yaml
   git add age.key
   ```

2. **Never hardcode secrets in templates:**
   ```yaml
   # ❌ Bad
   env:
     API_KEY: "hardcoded-secret-here"
   
   # ✅ Good
   env:
     API_KEY: "#{ myapp_api_key }#"
   ```

3. **Never skip SOPS encryption:**
   ```bash
   # ❌ Bad - creates unencrypted secret
   kubectl create secret generic myapp-secret --from-literal=key=value
   
   # ✅ Good - use template system
   task configure --yes
   ```

4. **Never share age.key insecurely:**
   - ❌ Email, Slack, unencrypted cloud storage
   - ✅ In-person, encrypted channel, hardware token

---

## Reference

### Related Documentation

- [CLAUDE.md](../CLAUDE.md) - Repository instructions and conventions
- [Volsync Backup Guide](./volsync-deployment-guide.md) - Backup secret patterns
- [Disaster Recovery](./disaster-recovery.md) - Secret recovery procedures

### External Resources

- [SOPS Documentation](https://github.com/getsops/sops)
- [Age Encryption](https://github.com/FiloSottile/age)
- [Flux SOPS Integration](https://fluxcd.io/flux/guides/mozilla-sops/)
- [Kubernetes Secrets Best Practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)

### Tools

- **SOPS:** Secret encryption/decryption
- **Age:** Modern encryption tool
- **makejinja:** Template rendering engine
- **Flux:** GitOps continuous delivery

---

**Last Reviewed:** 2026-06-11  
**Next Review:** 2026-09-11 (quarterly)
