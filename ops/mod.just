set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT     := source_directory() + "/.."

# ─── Cluster Operations ───────────────────────────────────────────────────────

# Show overall cluster health: Argo CD status, failed pods, PVCs, recent warnings
status:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "Argo CD Applications"
    APP_ISSUES=$(kubectl -n argo-system get applications -o json | jq -r '.items[]
        | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
        | "\(.metadata.name): sync=\(.status.sync.status) health=\(.status.health.status)"')
    if [[ -z "$APP_ISSUES" ]]; then
        echo "All Applications Synced & Healthy"
    else
        echo "$APP_ISSUES"
    fi

    echo ""
    gum style --foreground 212 --bold "Failed / CrashLooping Pods"
    kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAME" || echo "All pods running or completed"

    echo ""
    gum style --foreground 212 --bold "PVC Usage"
    kubectl get pvc -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.capacity.storage)"'

    echo ""
    gum style --foreground 212 --bold "Recent Warning Events"
    kubectl get events -A --sort-by='.lastTimestamp' | grep -i "warning\|error" | tail -10 || echo "No recent warnings"

# Trigger a one-off backup on all Volsync sources (usage: just ops volsync-snapshot-all [--dry-run] [--only local|r2] [label])
volsync-snapshot-all *ARGS:
    {{REPO_ROOT}}/scripts/volsync-snapshot-all.sh {{ARGS}}

# Get logs for an app pod (usage: just ops logs APP [NAMESPACE])
logs APP NAMESPACE="":
    #!/usr/bin/env bash
    set -euo pipefail
    NS="{{NAMESPACE}}"
    if [[ -z "$NS" ]]; then
        NS=$(kubectl get pods -A -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.namespace}')
    fi
    POD=$(kubectl get pods -n "$NS" -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.name}')
    gum style --foreground 212 "Fetching logs from $NS/$POD..."
    kubectl logs -n "$NS" "$POD" --tail=100 -f

# Show pods with errors or in CrashLoopBackOff
pod-errors:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "Pods Not Running"
    kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAME" || echo "All pods running or completed"
    echo ""
    gum style --foreground 212 --bold "Recent Pod Warning Events"
    kubectl get events -A --sort-by='.lastTimestamp' --field-selector type=Warning | tail -20 || echo "No recent warning events"

# Restart an app deployment (usage: just ops restart APP [NAMESPACE])
restart APP NAMESPACE="":
    #!/usr/bin/env bash
    set -euo pipefail
    NS="{{NAMESPACE}}"
    if [[ -z "$NS" ]]; then
        NS=$(kubectl get pods -A -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.namespace}')
    fi
    gum style --foreground 212 "Restarting {{APP}} in $NS..."
    kubectl rollout restart deployment -n "$NS" -l app.kubernetes.io/name={{APP}}

# Describe a Kubernetes resource (usage: just ops describe TYPE NAME [NAMESPACE])
describe TYPE NAME NAMESPACE="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{NAMESPACE}}" ]]; then
        kubectl describe {{TYPE}} {{NAME}}
    else
        kubectl describe {{TYPE}} -n {{NAMESPACE}} {{NAME}}
    fi

# Verify Prometheus monitoring coverage and target health
monitoring-status:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "ServiceMonitors & PodMonitors"
    kubectl get servicemonitors,podmonitors -A | wc -l

    echo ""
    gum style --foreground 212 --bold "Prometheus Targets"
    kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 5
    curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq -r \
        '.data.activeTargets | group_by(.health) | map({health: .[0].health, count: length}) | .[] | "\(.health): \(.count)"' \
        || echo "Unable to reach Prometheus (port-forward may have failed)"
    kill "$PF_PID" 2>/dev/null || true

    echo ""
    gum style --foreground 212 --bold "Gatus Status"
    kubectl get pods -n observability -l app.kubernetes.io/name=gatus \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Not found"

# ─── Storage Operations ───────────────────────────────────────────────────────

# Bootstrap SeaweedFS S3 storage (creates buckets, keys, updates cluster.toml)
bootstrap-seaweedfs:
    bash "{{REPO_ROOT}}/scripts/bootstrap-seaweedfs.sh"

# Restore a PVC from Volsync backup (usage: just ops restore-pvc NAMESPACE PVC CAPACITY)
restore-pvc NAMESPACE PVC CAPACITY:
    bash "{{REPO_ROOT}}/scripts/restore-pvc.sh" "{{NAMESPACE}}" "{{PVC}}" "{{CAPACITY}}"

# Show Volsync backup status for all PVCs
backup-status:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "Volsync Backup Status"
    kubectl get replicationsource -A \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SOURCE_PVC:.spec.sourcePVC,LAST_SYNC:.status.lastSyncTime,NEXT_SYNC:.status.nextSyncTime

# Show PVC capacity and storage class across all namespaces
pvc-usage:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "PVC Capacity"
    kubectl get pvc -A -o json | jq -r \
        '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.capacity.storage // "Pending") (\(.spec.storageClassName))"' | sort

# Show Longhorn volume and node status
longhorn-status:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --foreground 212 --bold "Longhorn Volumes"
    kubectl get volumes.longhorn.io -n storage \
        -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,SIZE:.spec.size
    echo ""
    gum style --foreground 212 --bold "Longhorn Nodes"
    kubectl get nodes.longhorn.io -n storage \
        -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status,SCHEDULABLE:.status.conditions[?(@.type==\"Schedulable\")].status"

# ─── OpenTofu: AWS KMS for Vault auto-unseal ──────────────────────────────────
# Requires env: R2_TFSTATE_ENDPOINT, R2_TFSTATE_ACCESS_KEY_ID, R2_TFSTATE_SECRET_ACCESS_KEY
# and AWS admin credentials (AWS_PROFILE or default chain).

TOFU_KMS_DIR := REPO_ROOT + "/ops/terraform/aws-kms"
VAULT_KMS_SECRET := REPO_ROOT + "/kubernetes/apps/vault/vault/app/vault-kms.sops.yaml"

# Run tofu in the aws-kms module (usage: just ops tofu-kms init|plan|apply|output ...)
tofu-kms *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${R2_TFSTATE_ENDPOINT:?set R2_TFSTATE_ENDPOINT}"
    : "${R2_TFSTATE_ACCESS_KEY_ID:?set R2_TFSTATE_ACCESS_KEY_ID}"
    : "${R2_TFSTATE_SECRET_ACCESS_KEY:?set R2_TFSTATE_SECRET_ACCESS_KEY}"
    cd "{{TOFU_KMS_DIR}}"
    tofu init -input=false -reconfigure \
        -backend-config="endpoints={s3=\"${R2_TFSTATE_ENDPOINT}\"}" \
        -backend-config="access_key=${R2_TFSTATE_ACCESS_KEY_ID}" \
        -backend-config="secret_key=${R2_TFSTATE_SECRET_ACCESS_KEY}" >/dev/null
    [[ "{{ARGS}}" == "init" ]] && { echo "tofu init OK"; exit 0; }
    tofu {{ARGS}}

# Write tofu outputs into a SOPS-encrypted Secret for Vault (no plaintext on disk)
vault-kms-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    OUT=$(just ops tofu-kms output -json)
    jq -e '.kms_key_id.value' <<<"$OUT" >/dev/null || { echo "Run 'just ops tofu-kms apply' first"; exit 1; }
    jq -r '"---
    apiVersion: v1
    kind: Secret
    metadata:
      name: vault-kms
      namespace: vault
    type: Opaque
    stringData:
      AWS_REGION: \(.aws_region.value)
      VAULT_AWSKMS_SEAL_KEY_ID: \(.kms_key_id.value)
      AWS_ACCESS_KEY_ID: \(.access_key_id.value)
      AWS_SECRET_ACCESS_KEY: \(.secret_access_key.value)"' <<<"$OUT" \
      | sed 's/^    //' \
      | sops encrypt --filename-override "{{VAULT_KMS_SECRET}}" --input-type yaml --output-type yaml /dev/stdin \
      > "{{VAULT_KMS_SECRET}}"
    echo "Wrote {{VAULT_KMS_SECRET}}"

# One-time Vault setup for the Raft snapshot CronJob (prompts for a root/admin token)
vault-snapshot-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r -s -p "Vault token: " TOKEN; echo
    kubectl -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN; export VAULT_TOKEN
      vault auth list -format=json | grep -q "\"kubernetes/\"" || vault auth enable kubernetes
      vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
      printf "path \"sys/storage/raft/snapshot\" {\n  capabilities = [\"read\"]\n}\n" \
        | vault policy write raft-snapshot -
      vault write auth/kubernetes/role/raft-snapshot \
        bound_service_account_names=vault-snapshot \
        bound_service_account_namespaces=vault \
        policies=raft-snapshot ttl=15m
      vault read auth/kubernetes/role/raft-snapshot
    ' <<<"$TOKEN"

# Run the Raft snapshot CronJob now and follow its logs
vault-snapshot-now:
    #!/usr/bin/env bash
    set -euo pipefail
    JOB="vault-raft-snapshot-manual-$(date +%s)"
    kubectl -n vault create job "$JOB" --from=cronjob/vault-raft-snapshot
    kubectl -n vault wait job/"$JOB" --for=condition=complete --timeout=300s || true
    kubectl -n vault logs job/"$JOB" -c snapshot
    kubectl -n vault logs job/"$JOB" -c upload

# Restore the latest R2 Raft snapshot into a throwaway Vault pod and verify it
vault-snapshot-test-restore:
    {{REPO_ROOT}}/scripts/vault-snapshot-test-restore.sh
