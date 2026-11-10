#!/usr/bin/env bash
# vault-snapshot-test-restore.sh - Prove the latest R2 Raft snapshot is restorable.
# Usage: ./vault-snapshot-test-restore.sh
#
# Starts a throwaway Vault pod (own Raft dir in emptyDir, same awskms seal),
# downloads the newest snapshot from R2, restores it with -force, checks it
# auto-unseals, and optionally lists secrets with your token. Production Vault
# is not touched: the pod has different labels, so no Service routes to it.

set -Eeuo pipefail

NS=vault
POD=vault-restore-test
VAULT_IMAGE=$(kubectl -n "$NS" get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}')
RCLONE_IMAGE=$(kubectl -n "$NS" get cronjob vault-raft-snapshot \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')

log() { echo "==> $*"; }
die() { echo "❌ $*" >&2; exit 1; }
vexec() { kubectl -n "$NS" exec "$POD" -c vault -- "$@"; }

cleanup() {
  log "Deleting $POD"
  kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null
}

create_pod() {
  log "Creating $POD ($VAULT_IMAGE)"
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels:
    app.kubernetes.io/name: vault-restore-test
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  initContainers:
    - name: fetch
      image: $RCLONE_IMAGE
      envFrom:
        - secretRef:
            name: vault-snapshot-r2
      env:
        - name: HOME
          value: /tmp
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -eu
          SRC="r2:\$R2_BUCKET/vault-snapshots"
          LATEST=\$(rclone lsf "\$SRC" --include "vault-*.snap" | sort | tail -1)
          [ -n "\$LATEST" ] || { echo "no snapshot found"; exit 1; }
          echo "latest snapshot: \$LATEST"
          rclone copyto "\$SRC/\$LATEST" /snap/latest.snap
          echo "\$LATEST" > /snap/name
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - { name: snap, mountPath: /snap }
  containers:
    - name: vault
      image: $VAULT_IMAGE
      command: ["/bin/sh", "-c"]
      args:
        - |
          cat > /tmp/config.hcl <<HCL
          ui = false
          disable_mlock = true
          api_addr     = "http://127.0.0.1:8200"
          cluster_addr = "https://127.0.0.1:8201"
          listener "tcp" {
            address     = "127.0.0.1:8200"
            tls_disable = 1
          }
          storage "raft" {
            path    = "/data"
            node_id = "restore-test"
          }
          seal "awskms" {}
          HCL
          exec vault server -config=/tmp/config.hcl
      env:
        - { name: VAULT_ADDR, value: "http://127.0.0.1:8200" }
        - { name: AWS_REGION, valueFrom: { secretKeyRef: { name: vault-kms, key: AWS_REGION } } }
        - { name: VAULT_AWSKMS_SEAL_KEY_ID, valueFrom: { secretKeyRef: { name: vault-kms, key: VAULT_AWSKMS_SEAL_KEY_ID } } }
        - { name: AWS_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: vault-kms, key: AWS_ACCESS_KEY_ID } } }
        - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: vault-kms, key: AWS_SECRET_ACCESS_KEY } } }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - { name: snap, mountPath: /snap, readOnly: true }
        - { name: data, mountPath: /data }
  volumes:
    - { name: snap, emptyDir: { sizeLimit: 512Mi } }
    - { name: data, emptyDir: { sizeLimit: 1Gi } }
YAML
  kubectl -n "$NS" wait pod/"$POD" --for=condition=Ready --timeout=180s >/dev/null ||
    { kubectl -n "$NS" logs "$POD" -c fetch || true; die "Pod did not start"; }
  log "Snapshot: $(vexec cat /snap/name)"
}

wait_api() {
  local _
  for _ in $(seq 1 30); do
    vexec vault status -format=json >/dev/null 2>&1 && return 0
    [[ $? -eq 2 ]] && return 0   # 2 = sealed/uninitialised but reachable
    sleep 2
  done
  die "Vault API not reachable in $POD"
}

restore_snapshot() {
  wait_api
  log "Initialising throwaway Vault"
  local root
  root=$(vexec vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json | jq -r .root_token)
  sleep 5
  log "Restoring snapshot (-force: snapshot comes from another cluster)"
  vexec sh -c "VAULT_TOKEN=$root vault operator raft snapshot restore -force /snap/latest.snap"
}

verify_unsealed() {
  local _ state
  for _ in $(seq 1 30); do
    state=$(vexec vault status -format=json 2>/dev/null || true)
    if [[ "$(jq -r '.sealed' <<<"$state" 2>/dev/null)" == "false" ]]; then
      jq -c '{type, sealed, storage_type, raft_committed_index}' <<<"$state"
      return 0
    fi
    sleep 2
  done
  die "Restored Vault did not auto-unseal"
}

list_secrets() {
  local token mounts m
  read -r -s -p "Production Vault token to list restored secrets (Enter to skip): " token || true; echo
  [[ -n "$token" ]] || return 0
  tok_exec() { kubectl -n "$NS" exec -i "$POD" -c vault -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec "$@"' _ "$@" <<<"$token"; }
  mounts=$(tok_exec sh -c 'vault secrets list -format=json')
  jq -r 'to_entries[] | "\(.key)\t\(.value.type)"' <<<"$mounts" | column -t
  for m in $(jq -r 'to_entries[] | select(.value.type == "kv") | .key' <<<"$mounts"); do
    echo "--- $m"
    tok_exec vault kv list "$m" || true
  done
}

main() {
  for tool in kubectl jq; do command -v "$tool" &>/dev/null || die "$tool not found"; done
  trap cleanup EXIT
  kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
  create_pod
  restore_snapshot
  verify_unsealed
  list_secrets
  echo "✅ Snapshot restore test passed"
}

main "$@"
