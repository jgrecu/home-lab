#!/usr/bin/env bash
# restore-pvc.sh - Restore a PVC from Volsync backup
# Usage: ./restore-pvc.sh <namespace> <pvc-name> <capacity>

set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

NAMESPACE=${1:-}
PVC_NAME=${2:-}
CAPACITY=${3:-}
STORAGE_CLASS=${4:-longhorn}

usage() {
  printf 'Usage:   %s <namespace> <pvc-name> <capacity> [storage-class]\n' "$0" >&2
  printf 'Example: %s forgejo forgejo-data 20Gi longhorn\n' "$0" >&2
  exit 1
}

[[ -z "$NAMESPACE" || -z "$PVC_NAME" || -z "$CAPACITY" ]] && usage

log info "Restoring PVC" "pvc=$PVC_NAME" "namespace=$NAMESPACE"

# Check if Volsync secret exists
SECRET_NAME="${PVC_NAME}-restic-secret"
if ! kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  log error "Volsync secret not found — PVC may not have backups configured" "secret=$SECRET_NAME"
fi

# Scale down any deployments using this PVC
log info "Finding deployments using PVC" "pvc=$PVC_NAME"
DEPLOY_DATA=$(kubectl get deployment -n "$NAMESPACE" -o json | \
  jq -r --arg pvc "$PVC_NAME" '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | "\(.metadata.name)=\(.spec.replicas)"')

declare -A DEPLOY_REPLICAS

cleanup() {
  if [[ ${#DEPLOY_REPLICAS[@]} -gt 0 ]]; then
    log warn "Cleanup: scaling deployments back up"
    for DEPLOY in "${!DEPLOY_REPLICAS[@]}"; do
      kubectl scale deployment -n "$NAMESPACE" "$DEPLOY" --replicas="${DEPLOY_REPLICAS[$DEPLOY]}" || true
    done
  fi
  kubectl delete replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE" --ignore-not-found || true
}
trap cleanup EXIT

if [[ -n "$DEPLOY_DATA" ]]; then
  while IFS='=' read -r name replicas; do
    DEPLOY_REPLICAS["$name"]=$replicas
    log debug "Found deployment" "name=$name" "replicas=$replicas"
  done <<< "$DEPLOY_DATA"

  for DEPLOY in "${!DEPLOY_REPLICAS[@]}"; do
    log info "Scaling down" "deployment=$DEPLOY"
    kubectl scale deployment -n "$NAMESPACE" "$DEPLOY" --replicas=0
  done

  log info "Waiting for pods to terminate"
  for DEPLOY in "${!DEPLOY_REPLICAS[@]}"; do
    kubectl rollout status deployment/"$DEPLOY" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
    kubectl wait --for=delete pods -n "$NAMESPACE" \
      --selector="$(kubectl get deployment -n "$NAMESPACE" "$DEPLOY" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')" \
      --timeout=120s 2>/dev/null || true
  done
else
  log info "No deployments found using this PVC"
fi

# Check if PVC exists and delete it before restore
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" &>/dev/null; then
  log info "Deleting existing PVC before restore" "pvc=$PVC_NAME"
  kubectl delete pvc -n "$NAMESPACE" "$PVC_NAME"
  kubectl wait --for=delete pvc/"$PVC_NAME" -n "$NAMESPACE" --timeout=120s || true
fi

# Create ReplicationDestination
log info "Creating ReplicationDestination"
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${PVC_NAME}-restore
  namespace: ${NAMESPACE}
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: ${SECRET_NAME}
    destinationPVC: ${PVC_NAME}
    storageClassName: ${STORAGE_CLASS}
    accessModes:
      - ReadWriteOnce
    capacity: ${CAPACITY}
    copyMethod: Direct
    enableSparseRestore: true
EOF

# Wait for restore to complete
log info "Waiting for restore to complete (this may take several minutes)"
if kubectl wait --for=condition=complete replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE" --timeout=600s; then
  log info "Restore completed successfully"
else
  kubectl describe replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE"
  log error "Restore failed or timed out" "pvc=$PVC_NAME" "namespace=$NAMESPACE"
fi

log info "PVC restore complete" "pvc=$PVC_NAME" "namespace=$NAMESPACE" "capacity=$CAPACITY"
log info "Verify restored data with: kubectl exec -n $NAMESPACE <pod-name> -- ls -la /path/to/mount"
