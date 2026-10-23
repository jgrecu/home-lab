set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT   := source_directory() + "/.."
SCRIPTS_DIR := REPO_ROOT + "/scripts"

# ─── Cluster Operations ───────────────────────────────────────────────────────

# Show overall cluster health: Flux status, failed pods, PVCs, recent warnings
status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Flux Status ==="
    FLUX_ISSUES=$(flux get kustomizations -A | grep -v "True.*Applied" | grep -v "NAME.*REVISION" || true)
    if [[ -z "$FLUX_ISSUES" ]]; then
        echo "All kustomizations healthy (Applied & Ready)"
    else
        echo "$FLUX_ISSUES"
    fi
    echo ""
    echo "=== Failed/CrashLooping Pods ==="
    kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAME" || echo "All pods running or completed"
    echo ""
    echo "=== PVC Usage ==="
    kubectl get pvc -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.capacity.storage)"'
    echo ""
    echo "=== Recent Warning Events ==="
    kubectl get events -A --sort-by='.lastTimestamp' | grep -i "warning\|error" | tail -10 || echo "No recent warnings"

# Get logs for an app pod (usage: just ops logs ARGS="radarr [namespace]")
logs APP NAMESPACE="":
    #!/usr/bin/env bash
    set -euo pipefail
    NS="{{NAMESPACE}}"
    if [[ -z "$NS" ]]; then
        NS=$(kubectl get pods -A -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.namespace}')
    fi
    POD=$(kubectl get pods -n "$NS" -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.name}')
    echo "Fetching logs from $NS/$POD..."
    kubectl logs -n "$NS" "$POD" --tail=100 -f

# Show pods with errors or in CrashLoopBackOff
pod-errors:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Pods Not Running ==="
    kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAME" || echo "All pods running or completed"
    echo ""
    echo "=== Recent Pod Warning Events ==="
    kubectl get events -A --sort-by='.lastTimestamp' --field-selector type=Warning | tail -20 || echo "No recent warning events"

# Restart an app deployment (usage: just ops restart APP [NAMESPACE])
restart APP NAMESPACE="":
    #!/usr/bin/env bash
    set -euo pipefail
    NS="{{NAMESPACE}}"
    if [[ -z "$NS" ]]; then
        NS=$(kubectl get pods -A -l app.kubernetes.io/name={{APP}} -o jsonpath='{.items[0].metadata.namespace}')
    fi
    echo "Restarting {{APP}} in namespace $NS..."
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
    echo "=== ServiceMonitors & PodMonitors ==="
    kubectl get servicemonitors,podmonitors -A | wc -l
    echo ""
    echo "=== Prometheus Targets ==="
    kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 5
    curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq -r \
        '.data.activeTargets | group_by(.health) | map({health: .[0].health, count: length}) | .[] | "\(.health): \(.count)"' \
        || echo "Unable to reach Prometheus (port-forward may have failed)"
    kill "$PF_PID" 2>/dev/null || true
    echo ""
    echo "=== Gatus Status ==="
    kubectl get pods -n observability -l app.kubernetes.io/name=gatus \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Not found"

# ─── Storage Operations ───────────────────────────────────────────────────────

# Bootstrap SeaweedFS S3 storage (creates buckets, keys, updates cluster.toml)
bootstrap-seaweedfs:
    bash "{{SCRIPTS_DIR}}/bootstrap-seaweedfs.sh"

# Restore a PVC from Volsync backup (usage: just ops restore-pvc NAMESPACE PVC CAPACITY)
restore-pvc NAMESPACE PVC CAPACITY:
    bash "{{SCRIPTS_DIR}}/restore-pvc.sh" "{{NAMESPACE}}" "{{PVC}}" "{{CAPACITY}}"

# Show Volsync backup status for all PVCs
backup-status:
    kubectl get replicationsource -A \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SOURCE_PVC:.spec.sourcePVC,LAST_SYNC:.status.lastSyncTime,NEXT_SYNC:.status.nextSyncTime

# Show PVC capacity and storage class across all namespaces
pvc-usage:
    kubectl get pvc -A -o json | jq -r \
        '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.capacity.storage // "Pending") (\(.spec.storageClassName))"' | sort

# Show Longhorn volume and node status
longhorn-status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Longhorn Volumes ==="
    kubectl get volumes.longhorn.io -n storage \
        -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,SIZE:.spec.size
    echo ""
    echo "=== Longhorn Nodes ==="
    kubectl get nodes.longhorn.io -n storage \
        -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status,SCHEDULABLE:.status.conditions[?(@.type==\"Schedulable\")].status"
