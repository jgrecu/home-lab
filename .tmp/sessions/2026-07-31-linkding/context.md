# Task Context: Linkding Bookmark Manager Deployment

Session ID: 2026-07-31-linkding
Created: 2026-07-31T00:00:00Z
Status: in_progress

## Current Request
Deploy Linkding (self-hosted bookmark manager) to the cloud namespace, accessible externally via Cloudflare tunnel. Two users (personal + work) created post-deploy via admin panel.

## Context Files (Standards to Follow)
- /Users/I337469/.config/opencode/context/core/standards/code-quality.md
- /Users/I337469/.config/opencode/context/development/infrastructure/kubernetes.md
- /Users/I337469/.config/opencode/context/development/infrastructure/devops-principles.md
- /Users/I337469/.config/opencode/context/development/infrastructure/docker.md
- /Users/I337469/.config/opencode/context/core/standards/security-patterns.md

## Reference Files (Source Material to Look At)
- templates/config/kubernetes/apps/cloud/nextcloud/ks.yaml.j2
- templates/config/kubernetes/apps/cloud/nextcloud/backup-ks.yaml.j2
- templates/config/kubernetes/apps/cloud/nextcloud/app/helmrelease.yaml.j2
- templates/config/kubernetes/apps/cloud/nextcloud/app/secret.sops.yaml.j2
- templates/config/kubernetes/apps/cloud/nextcloud/backup/replicationsource.yaml.j2
- templates/config/kubernetes/apps/cloud/nextcloud/backup/secret.sops.yaml.j2
- templates/config/kubernetes/apps/downloads/autobrr/app/helmrelease.yaml.j2
- templates/config/kubernetes/apps/cloud/kustomization.yaml.j2
- templates/config/kubernetes/apps/observability/gatus/app/helmrelease.yaml.j2
- cluster.yaml

## Key Technical Details
- Image: sissbruecker/linkding:1.45.0
- Port: 9090
- Data dir: /etc/linkding/data
- Health endpoint: /health (returns HTTP 200)
- Runs as user 1000 (non-root)
- Namespace: cloud (baseline PSS - Nextcloud already there)
- Gateway: envoy-external (Cloudflare tunnel)
- Helm chart: bjw-s app-template 5.0.1 (oci://ghcr.io/bjw-s-labs/helm/app-template)

## Components
1. Flux Kustomization (ks.yaml.j2)
2. OCI Repository (app-template 5.0.1)
3. HelmRelease with:
   - Non-root security context (UID/GID 1000)
   - Longhorn PVC 2Gi for SQLite data
   - envoy-external HTTPRoute
   - Homepage auto-discovery annotations (group: Cloud)
   - Admin password from SOPS-encrypted secret
4. App Secret (admin password from cluster.yaml)
5. Backup Flux Kustomization (backup-ks.yaml.j2)
6. Volsync ReplicationSource (daily 2AM, 7d/4w/3m retention)
7. Backup S3 Secret (SOPS encrypted, SeaweedFS)

## Constraints
- Template delimiters: #{ }# for Jinja2, ${ } for Helm runtime substitution
- Never edit kubernetes/ directly - always templates/
- SOPS encryption via task configure --yes
- Always keep cluster.sample.yaml in sync with cluster.yaml

## Exit Criteria
- [ ] All 9 template files created
- [ ] cloud/kustomization.yaml.j2 updated with linkding entries
- [ ] gatus helmrelease updated with linkding health checks
- [ ] cluster.yaml + cluster.sample.yaml updated with linkding_admin_password
- [ ] task configure --yes runs without errors
