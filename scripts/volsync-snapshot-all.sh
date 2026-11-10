#!/usr/bin/env bash
# volsync-snapshot-all.sh - Trigger a one-off backup on every Volsync ReplicationSource
# Usage: ./volsync-snapshot-all.sh [--dry-run] [--only local|r2] [label]
#   TIMEOUT_MIN=60 (env) - max minutes to wait for all sources
# The GitOps controller owning the ReplicationSources is paused during the run so it
# does not revert the one-off trigger, and always resumed on exit (restoring the
# regular schedule triggers from git):
#   - Argo CD: auto-sync of the owning Applications (tracking-id annotation)
#   - Flux:    all Kustomizations (before the Argo CD cut-over)

set -Eeuo pipefail

DRY_RUN=false
ONLY=""
LABEL=""
TIMEOUT_MIN=${TIMEOUT_MIN:-60}
POLL_SECONDS=15
FLUX_SUSPENDED=false
ARGO_PAUSED=()          # Applications whose auto-sync we disabled
ARGO_POLICY_DIR=$(mktemp -d)

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

# Argo CD Application owning a ReplicationSource ("ns/name"), from the tracking annotation
argo_owner() {
  kubectl get replicationsources.volsync.backube "${1#*/}" -n "${1%%/*}" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' | cut -d: -f1
}

is_argo_managed() { [[ -n "$(argo_owner "$1")" ]]; }

pause_argo() {
  local app
  echo "==> Pausing auto-sync of owning Argo CD Applications"
  for app in $(printf '%s\n' "$@" | while read -r s; do argo_owner "$s"; done | sort -u); do
    kubectl -n argo-system get application "$app" -o jsonpath='{.spec.syncPolicy}' > "$ARGO_POLICY_DIR/$app.json"
    kubectl -n argo-system patch application "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
    ARGO_PAUSED+=("$app")
  done
}

# Restore the saved syncPolicy; selfHeal then re-applies the git schedule triggers
resume_argo() {
  local app
  [[ ${#ARGO_PAUSED[@]} -gt 0 ]] || return 0
  echo "==> Restoring auto-sync of ${#ARGO_PAUSED[@]} Argo CD Applications"
  for app in "${ARGO_PAUSED[@]}"; do
    kubectl -n argo-system patch application "$app" --type merge \
      -p "{\"spec\":{\"syncPolicy\":$(cat "$ARGO_POLICY_DIR/$app.json")}}" >/dev/null ||
      echo "WARNING: restore syncPolicy of $app by hand (saved in $ARGO_POLICY_DIR/$app.json)"
    kubectl -n argo-system annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
  wait_schedules_restored
}

wait_schedules_restored() {
  local _
  for _ in $(seq 1 20); do
    [[ -z "$(leftover_triggers)" ]] && break
    sleep 15
  done
  verify_schedules_restored
}

leftover_triggers() {
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -r '.items[] | select(.spec.trigger.schedule == null or .spec.trigger.manual != null)
      | "\(.metadata.namespace)/\(.metadata.name)"'
}

# Server-side apply (Argo CD) never removes fields owned by another manager, so the
# one-off manual trigger set by this script must be removed by this script.
clear_manual_triggers() {
  local s
  while read -r s; do
    [[ -n "$s" ]] || continue
    kubectl patch replicationsource.volsync.backube "${s#*/}" -n "${s%%/*}" --type json \
      -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null 2>&1 || true
  done < <(kubectl get replicationsources.volsync.backube -A -o json |
    jq -r --arg l "$LABEL" '.items[] | select(.spec.trigger.manual == $l) | "\(.metadata.namespace)/\(.metadata.name)"')
}

resume_gitops() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  clear_manual_triggers
  resume_argo
  resume_flux
  rm -rf "$ARGO_POLICY_DIR"
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

  trap resume_gitops EXIT
  if is_argo_managed "${sources[0]}"; then
    pause_argo "${sources[@]}"
  else
    warn_not_ready
    suspend_flux
  fi

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
