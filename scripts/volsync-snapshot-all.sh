#!/usr/bin/env bash
# volsync-snapshot-all.sh - Trigger a one-off backup on every Volsync ReplicationSource
# Usage: ./volsync-snapshot-all.sh [--dry-run] [--only local|r2] [label]
#   TIMEOUT_MIN=60 (env) - max minutes to wait for all sources
# Flux Kustomizations are suspended during the run and always resumed on exit,
# which restores the regular schedule triggers.

set -Eeuo pipefail

DRY_RUN=false
ONLY=""
LABEL=""
TIMEOUT_MIN=${TIMEOUT_MIN:-60}
POLL_SECONDS=15
FLUX_SUSPENDED=false

usage() {
  echo "Usage: $0 [--dry-run] [--only local|r2] [label]"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --only) ONLY=${2:-}; [[ "$ONLY" == "local" || "$ONLY" == "r2" ]] || usage; shift ;;
      -h|--help) usage ;;
      *) LABEL=$1 ;;
    esac
    shift
  done
  LABEL=${LABEL:-pre-argo-$(date +%Y%m%d)}
}

require_tools() {
  local tool
  for tool in kubectl flux jq; do
    command -v "$tool" &>/dev/null || { echo "Error: $tool not found"; exit 1; }
  done
  kubectl version --request-timeout=10s &>/dev/null || { echo "Error: cluster unreachable"; exit 1; }
}

# Prints "namespace/name" for each ReplicationSource matching the --only filter
list_sources() {
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -r --arg only "$ONLY" '.items[]
      | select($only == "" or ($only == "r2") == (.metadata.name | test("-r2$")))
      | "\(.metadata.namespace)/\(.metadata.name)"'
}

# Prints "namespace name" for every Flux Kustomization in the cluster
list_kustomizations() {
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json |
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"'
}

warn_not_ready() {
  local not_ready
  not_ready=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json |
    jq -r '.items[] | select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True")
      | "\(.metadata.namespace)/\(.metadata.name)"')
  [[ -z "$not_ready" ]] || { echo "WARNING: Kustomizations not Ready:"; echo "$not_ready"; }
}

suspend_flux() {
  echo "==> Suspending all Flux Kustomizations"
  FLUX_SUSPENDED=true
  local ns name
  while read -r ns name; do
    flux suspend kustomization "$name" -n "$ns" >/dev/null
  done < <(list_kustomizations)
}

# Resume and force-reconcile so Flux re-applies the Git schedule triggers
resume_flux() {
  [[ "$FLUX_SUSPENDED" == "true" ]] || return 0
  echo "==> Resuming and reconciling all Flux Kustomizations"
  local ns name
  while read -r ns name; do
    flux resume kustomization "$name" -n "$ns" --timeout=3m >/dev/null 2>&1 ||
      echo "WARNING: resume/reconcile failed for $ns/$name"
  done < <(list_kustomizations)
  verify_schedules_restored
}

verify_schedules_restored() {
  local leftovers
  leftovers=$(kubectl get replicationsources.volsync.backube -A -o json |
    jq -r '.items[] | select(.spec.trigger.schedule == null or .spec.trigger.manual != null)
      | "\(.metadata.namespace)/\(.metadata.name)"')
  if [[ -n "$leftovers" ]]; then
    echo "❌ Schedule trigger not restored on:"; echo "$leftovers"
    exit 1
  fi
  echo "==> All schedule triggers restored"
}

trigger_source() {
  local ns=${1%%/*} name=${1#*/}
  kubectl patch replicationsource.volsync.backube "$name" -n "$ns" --type merge \
    -p "{\"spec\":{\"trigger\":{\"schedule\":null,\"manual\":\"$LABEL\"}}}" >/dev/null
}

# Prints sources whose lastManualSync does not yet equal LABEL
pending_sources() {
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -r --arg label "$LABEL" '.items[]
      | select(.status.lastManualSync != $label)
      | "\(.metadata.namespace)/\(.metadata.name)"' |
    grep -Fxf <(printf '%s\n' "$@") || true
}

wait_for_sources() {
  local deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 )) pending
  while true; do
    pending=$(pending_sources "$@")
    [[ -z "$pending" ]] && return 0
    echo "    $(( $# - $(wc -l <<<"$pending") ))/$# done"
    if (( $(date +%s) >= deadline )); then
      echo "Error: timed out after ${TIMEOUT_MIN}m. Pending:"; echo "$pending"
      return 1
    fi
    sleep "$POLL_SECONDS"
  done
}

report() {
  echo "==> Results"
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -r --arg label "$LABEL" '["NAMESPACE","NAME","SYNCED","RESULT","DURATION"],
      (.items[] | [.metadata.namespace, .metadata.name,
        (.status.lastManualSync == $label | tostring),
        (.status.latestMoverStatus.result // "-"), (.status.lastSyncDuration // "-")])
      | @tsv' | column -t
}

has_failures() {
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -e --arg label "$LABEL" '[.items[] | select(.status.lastManualSync == $label
      and .status.latestMoverStatus.result == "Failed")] | length > 0' >/dev/null
}

main() {
  parse_args "$@"
  require_tools

  local sources
  mapfile -t sources < <(list_sources)
  (( ${#sources[@]} > 0 )) || { echo "No ReplicationSources found"; exit 1; }
  echo "==> ${#sources[@]} ReplicationSources, label: $LABEL"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  %s\n' "${sources[@]}"
    exit 0
  fi

  warn_not_ready
  trap resume_flux EXIT
  suspend_flux

  echo "==> Triggering backups"
  local src
  for src in "${sources[@]}"; do trigger_source "$src"; done

  echo "==> Waiting for completion (timeout ${TIMEOUT_MIN}m)"
  local rc=0
  wait_for_sources "${sources[@]}" || rc=1
  report
  has_failures && { echo "❌ Some backups failed"; rc=1; }
  [[ $rc -eq 0 ]] && echo "✅ All backups completed for label $LABEL"
  return $rc
}

main "$@"
