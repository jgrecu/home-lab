#!/usr/bin/env bash
# vault-migrate-raft.sh - Migrate Vault storage from "file" to integrated Raft, in place.
# Usage: ./vault-migrate-raft.sh
#
# Steps (each gated by a check):
#   1. Verify auto-unseal (restart vault-0, expect awskms + unsealed)
#   2. Fresh volsync R2 backup of data-vault-0
#   3. Suspend Flux (ks + hr), scale Vault to 0
#   4. Job on data-vault-0: move file data to ./file, migrate into ./raft
#   5. Wait until the Raft HelmRelease is on origin/main, then resume Flux
#   6. Verify Vault runs on Raft, unsealed
# Rollback: data stays in /vault/data/file untouched (see docs at end of run).

set -Eeuo pipefail

NS=vault
POD=vault-0
PVC=data-vault-0
R2_SOURCE=vault-data-backup-r2
HR_PATH=kubernetes/apps/vault/vault/app/helmrelease.yaml
JOB=vault-migrate-raft
IMAGE=$(kubectl -n "$NS" get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}')
FLUX_SUSPENDED=false

log() { echo "==> $*"; }
die() { echo "❌ $*" >&2; exit 1; }

vault_status() { kubectl -n "$NS" exec "$POD" -- vault status -format=json 2>/dev/null || true; }

confirm() {
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == "y" ]] || die "Aborted"
}

wait_unsealed() {
  local status
  for _ in $(seq 1 30); do
    status=$(vault_status)
    [[ "$(jq -r '.sealed // empty' <<<"$status")" == "false" ]] && { echo "$status"; return 0; }
    sleep 5
  done
  die "vault-0 did not unseal within 150s"
}

verify_auto_unseal() {
  log "Step 1: restart $POD and verify AWS KMS auto-unseal"
  kubectl -n "$NS" delete pod "$POD" --wait=true
  kubectl -n "$NS" wait pod/"$POD" --for=jsonpath='{.status.phase}'=Running --timeout=180s
  local status
  status=$(wait_unsealed)
  [[ "$(jq -r .type <<<"$status")" == "awskms" ]] || die "Seal type is not awskms"
  [[ "$(jq -r .storage_type <<<"$status")" == "file" ]] || die "Storage is not 'file' - already migrated?"
  log "Auto-unseal OK"
}

backup_r2() {
  local label="pre-raft-$(date +%Y%m%d%H%M)"
  log "Step 2: volsync backup $R2_SOURCE ($label)"
  kubectl -n "$NS" patch replicationsource "$R2_SOURCE" --type merge \
    -p "{\"spec\":{\"trigger\":{\"manual\":\"$label\"}}}" >/dev/null

  for _ in $(seq 1 60); do
    if [[ "$(kubectl -n "$NS" get replicationsource "$R2_SOURCE" -o jsonpath='{.status.lastManualSync}')" == "$label" ]]; then
      local result
      result=$(kubectl -n "$NS" get replicationsource "$R2_SOURCE" -o jsonpath='{.status.latestMoverStatus.result}')
      [[ "$result" == "Successful" ]] || die "Backup result: $result"
      log "Backup OK"
      return 0
    fi
    sleep 10
  done
  die "Backup did not finish within 10m"
}

restore_backup_schedule() {
  flux reconcile ks vault-backup -n flux-system >/dev/null 2>&1 ||
    echo "WARNING: run 'flux reconcile ks vault-backup -n flux-system' to restore the backup schedule"
}

suspend_flux() {
  log "Step 3: suspend Flux and scale Vault to 0"
  flux suspend ks vault -n "$NS"
  flux suspend hr vault -n "$NS"
  FLUX_SUSPENDED=true
  kubectl -n "$NS" scale sts vault --replicas=0
  kubectl -n "$NS" wait pod/"$POD" --for=delete --timeout=180s
}

resume_flux() {
  [[ "$FLUX_SUSPENDED" == "true" ]] || return 0
  log "Resuming Flux (ks + hr)"
  flux resume ks vault -n "$NS" --timeout=5m || true
  flux resume hr vault -n "$NS" --timeout=5m || true
  FLUX_SUSPENDED=false
}

on_exit() {
  local rc=$?
  restore_backup_schedule
  if [[ $rc -ne 0 && "$FLUX_SUSPENDED" == "true" ]]; then
    echo "❌ Failed while Flux is suspended. Vault is scaled to 0 and data is intact."
    echo "   Inspect: kubectl -n $NS logs job/$JOB"
    echo "   Rollback: see the ROLLBACK section in this script, then resume Flux:"
    echo "     flux resume ks vault -n $NS && flux resume hr vault -n $NS"
  fi
}

# Moves file-backend data into ./file (idempotent), then copies it into ./raft.
# shellcheck disable=SC2016  # expanded inside the Job, not here
JOB_SCRIPT='set -eu
cd /vault/data
if [ ! -d file ]; then
  mkdir file
  for d in core logical sys; do
    if [ -e "$d" ]; then mv "$d" file/; fi
  done
fi
if [ -d raft ]; then echo "raft dir already exists - refusing to overwrite"; exit 1; fi
mkdir raft
cat > /tmp/migrate.hcl <<HCL
storage_source "file" {
  path = "/vault/data/file"
}
storage_destination "raft" {
  path    = "/vault/data/raft"
  node_id = "vault-0"
}
cluster_addr = "https://vault-0.vault-internal:8201"
HCL
vault operator migrate -config=/tmp/migrate.hcl
ls -la /vault/data /vault/data/raft'

run_migration_job() {
  log "Step 4: run migration Job ($IMAGE)"
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=true
  # shellcheck disable=SC2001
  kubectl -n "$NS" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: migrate
          image: $IMAGE
          command: ["/bin/sh", "-c"]
          args:
            - |
$(sed 's/^/              /' <<<"$JOB_SCRIPT")
          securityContext:
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: data
              mountPath: /vault/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: $PVC
YAML
  if ! kubectl -n "$NS" wait job/"$JOB" --for=condition=complete --timeout=600s; then
    kubectl -n "$NS" logs job/"$JOB" || true
    die "Migration Job failed"
  fi
  kubectl -n "$NS" logs job/"$JOB" | tail -20
  log "Migration OK"
}

wait_for_raft_release() {
  log "Step 5: Raft HelmRelease must be on origin/main before Flux is resumed"
  echo "   Commit and push the Raft change to $HR_PATH now."
  until git fetch -q origin main && git show "origin/main:$HR_PATH" | grep -q 'storage "raft"'; do
    read -r -p "   Not on origin/main yet. Press Enter to re-check (Ctrl-C keeps Flux suspended)... " _
  done
  log "Raft HelmRelease found on origin/main"
  flux reconcile source git flux-system -n flux-system >/dev/null
}

verify_raft() {
  log "Step 6: verify Vault on Raft"
  kubectl -n "$NS" wait pod/"$POD" --for=jsonpath='{.status.phase}'=Running --timeout=300s
  local status
  status=$(wait_unsealed)
  [[ "$(jq -r .storage_type <<<"$status")" == "raft" ]] || die "Storage type is not raft"
  kubectl -n "$NS" exec "$POD" -- vault status
}

main() {
  for tool in kubectl flux jq git; do command -v "$tool" &>/dev/null || die "$tool not found"; done
  git fetch -q origin main
  if git show "origin/main:$HR_PATH" | grep -q 'storage "raft"'; then
    die "Raft config is already on origin/main - it must only be pushed at step 5"
  fi
  confirm "Migrate Vault in namespace '$NS' from file to Raft? (Vault is down for a few minutes)"
  trap on_exit EXIT
  verify_auto_unseal
  backup_r2
  suspend_flux
  run_migration_job
  wait_for_raft_release
  resume_flux
  verify_raft
  echo "✅ Vault migrated to Raft. Old data kept in /vault/data/file (delete after a few days)."
}

# ROLLBACK (Vault scaled to 0, Flux suspended):
#   1. Revert the Raft HelmRelease change on main.
#   2. Run a pod on data-vault-0 that does:
#        cd /vault/data && rm -rf raft && mv file/* . && rmdir file
#   3. flux resume ks vault -n vault && flux resume hr vault -n vault

main "$@"
