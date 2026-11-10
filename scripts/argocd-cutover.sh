#!/usr/bin/env bash
# argocd-cutover.sh - In-place Flux -> Argo CD cut-over, one phase at a time.
# Runbook: docs/argocd-cutover.md (read it first).
#
# Usage: ./argocd-cutover.sh <phase> [--apply] [args]
#   precheck            read-only checks + snapshot of PVC UIDs / Helm releases
#   backup              one-off volsync backup of every PVC (Flux mode)
#   install-argo        install Argo CD (helmfile release argo-cd) + bootstrap secrets
#   freeze-flux         suspend all Flux objects, stop flux-operator, flux uninstall --keep-namespace
#   adopt               (after merging the PR) create child Applications WITHOUT auto-sync + root apps
#   diff <wave>         argocd app diff for every Application of a wave (read-only)
#   sync <wave>         sync a wave and re-enable its auto-sync
#   verify              Synced/Healthy, PVC UIDs unchanged, volsync schedules, vault
#   cleanup             delete leftover Helm release secrets and the flux-system namespace
#
# Mutating phases are DRY-RUN unless --apply is given; with --apply every step asks first.

set -Eeuo pipefail
trap 'echo "❌ $(basename "$0") failed at line $LINENO: $BASH_COMMAND" >&2' ERR

REPO_ROOT=$(git rev-parse --show-toplevel)
STATE=$REPO_ROOT/.tmp/cutover
ARGO_NS=argo-system
APPLY=false
PHASE=${1:-}
shift || true

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() { echo "❌ $*" >&2; exit 1; }

parse_flags() {
  local a
  ARGS=()
  for a in "$@"; do
    if [[ "$a" == "--apply" ]]; then APPLY=true; else ARGS+=("$a"); fi
  done
}

# Run a mutating command: print in dry-run, confirm + execute with --apply
run() {
  if [[ "$APPLY" != "true" ]]; then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  printf '   + %s\n' "$*"
  "$@"
}

confirm() {
  [[ "$APPLY" == "true" ]] || return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == "y" ]] || die "Aborted by user"
}

require() {
  local t
  for t in "$@"; do command -v "$t" &>/dev/null || die "$t not found (mise install)"; done
}

# argocd --core talks to the cluster directly and uses the kube context's namespace
argocd_core() {
  local kc="$STATE/kubeconfig-argocd"
  if [[ ! -f "$kc" ]]; then
    mkdir -p "$STATE"
    (umask 077; kubectl config view --raw --minify > "$kc")
    KUBECONFIG="$kc" kubectl config set-context --current --namespace "$ARGO_NS" >/dev/null
  fi
  KUBECONFIG="$kc" argocd --core "$@"
}

# ── precheck ────────────────────────────────────────────────────────────────

snapshot_state() {
  mkdir -p "$STATE"
  kubectl get pvc -A -o json |
    jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(.metadata.uid) \(.spec.volumeName)"' |
    sort > "$STATE/pvc-uids.txt"
  kubectl get secrets -A -l owner=helm -o json |
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.labels.name) \(.metadata.name)"' |
    sort > "$STATE/helm-release-secrets.txt"
  log "Recorded $(wc -l < "$STATE/pvc-uids.txt" | tr -d ' ') PVCs and $(wc -l < "$STATE/helm-release-secrets.txt" | tr -d ' ') Helm release secrets in ${STATE#"$REPO_ROOT"/}"
}

phase_precheck() {
  require kubectl flux jq helmfile sops argocd
  log "Context: $(kubectl config current-context)"
  local not_ready sealed
  not_ready=$(flux get all -A --status-selector ready=false 2>/dev/null | grep -vcE '^(NAME|$)' || true)
  [[ "$not_ready" == "0" ]] || warn "$not_ready Flux objects are not Ready (flux get all -A --status-selector ready=false)"
  sealed=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed)
  [[ "$sealed" == "false" ]] || warn "Vault is sealed or unreachable"
  kubectl get ns "$ARGO_NS" &>/dev/null && warn "namespace $ARGO_NS already exists"
  [[ "$(git -C "$REPO_ROOT" branch --show-current)" == "feat/argocd-migration" ]] ||
    warn "not on feat/argocd-migration: install-argo must run from the migration branch"
  snapshot_state
  log "Precheck done. Next: backup"
}

phase_backup() {
  log "One-off backup of every ReplicationSource (Flux mode, schedules restored afterwards)"
  confirm "Run scripts/volsync-snapshot-all.sh now?"
  run "$REPO_ROOT/scripts/volsync-snapshot-all.sh" "pre-argocd-$(date +%Y%m%d)"
}

# ── install-argo ────────────────────────────────────────────────────────────

phase_install_argo() {
  require helmfile kubectl sops
  [[ -f "$STATE/pvc-uids.txt" ]] || die "run precheck first"
  log "Install Argo CD next to Flux (no Applications yet, nothing is adopted)"
  confirm "Create $ARGO_NS, apply bootstrap secrets and helmfile release argo-cd?"
  run kubectl create namespace "$ARGO_NS"
  local s
  for s in bootstrap/sops-age.sops.yaml kubernetes/argo/repositories/github.sops.yaml; do
    run sops exec-file "$REPO_ROOT/$s" "kubectl -n $ARGO_NS apply --server-side -f {}"
  done
  run env ROOT_DIR="$REPO_ROOT" helmfile --file "$REPO_ROOT/bootstrap/helmfile.d/01-apps.yaml" \
    --selector name=argo-cd sync --skip-needs --hide-notes
  run kubectl -n "$ARGO_NS" rollout status deploy/argocd-repo-server --timeout=10m
  run kubectl -n "$ARGO_NS" rollout status statefulset/argocd-application-controller --timeout=10m
  log "Argo CD installed. Next: freeze-flux"
}

# ── freeze-flux ─────────────────────────────────────────────────────────────

phase_freeze_flux() {
  require flux kubectl helm
  log "Stop Flux WITHOUT touching workloads (point of no easy return: Flux CRs are deleted)"
  confirm "Suspend all Flux objects, stop flux-operator and run 'flux uninstall --keep-namespace'?"
  local kind ns name
  for kind in kustomization.kustomize.toolkit.fluxcd.io helmrelease.helm.toolkit.fluxcd.io; do
    while read -r ns name; do
      run flux suspend "${kind%%.*}" "$name" -n "$ns"
    done < <(kubectl get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}')
  done
  # flux-operator would re-create the controllers removed by flux uninstall
  run kubectl -n flux-system scale deployment flux-operator --replicas=0
  run flux uninstall --keep-namespace --silent
  run helm -n flux-system uninstall flux-instance --no-hooks
  run helm -n flux-system uninstall flux-operator --no-hooks
  if [[ "$APPLY" == "true" ]]; then
    kubectl get crd -o name | grep -q 'toolkit.fluxcd.io' && warn "Flux CRDs still present"
    verify_pvc_uids
  fi
  log "Flux removed, workloads untouched. Next: merge the PR, then: adopt"
}

# ── adopt ───────────────────────────────────────────────────────────────────

phase_adopt() {
  require kubectl yq git
  git -C "$REPO_ROOT" fetch -q origin main
  git -C "$REPO_ROOT" show origin/main:kubernetes/components/apps.yaml &>/dev/null ||
    die "origin/main has no Argo CD layout yet - merge the PR first"
  kubectl get crd kustomizations.kustomize.toolkit.fluxcd.io &>/dev/null && die "Flux still installed - run freeze-flux"
  log "Create child Applications with auto-sync DISABLED, then the root Applications"
  confirm "Apply $(find "$REPO_ROOT/kubernetes/argo/apps" -name '*.yaml' | wc -l | tr -d ' ') Applications (no auto-sync) + projects/repositories/apps roots?"
  run kubectl apply --server-side -f "$REPO_ROOT/kubernetes/components/cluster.yaml"
  run kubectl apply --server-side -f "$REPO_ROOT/kubernetes/components/repositories.yaml"
  local f
  while IFS= read -r f; do
    if [[ "$APPLY" == "true" ]]; then
      yq 'del(.spec.syncPolicy.automated)' "$f" | kubectl apply --server-side -f - >/dev/null
    else
      printf '   [dry-run] apply %s without .spec.syncPolicy.automated\n' "${f#"$REPO_ROOT"/}"
    fi
  done < <(find "$REPO_ROOT/kubernetes/argo/apps" -name '*.yaml' | sort)
  # root 'apps' ignores child .spec.syncPolicy, so children stay paused until 'sync <wave>'
  run kubectl apply --server-side -f "$REPO_ROOT/kubernetes/components/apps.yaml"
  log "Waves to adopt: $(list_waves | tr '\n' ' ')"
  log "Next: diff <wave> / sync <wave>, lowest wave first"
}

# ── waves ───────────────────────────────────────────────────────────────────

list_waves() {
  find "$REPO_ROOT/kubernetes/argo/apps" -name '*.yaml' -exec yq -N '.metadata.annotations."argocd.argoproj.io/sync-wave"' {} + |
    sort -n | uniq
}

apps_in_wave() {
  local f
  while IFS= read -r f; do
    if [[ "$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$f")" == "$1" ]]; then
      yq '.metadata.name' "$f"
    fi
  done < <(find "$REPO_ROOT/kubernetes/argo/apps" -name '*.yaml' | sort)
}

phase_diff() {
  local wave=${ARGS[0]:?usage: diff <wave>} app rc
  require argocd
  for app in $(apps_in_wave "$wave"); do
    rc=0
    argocd_core app diff "$app" --server-side-generate > "$STATE/diff-$app.txt" 2>&1 || rc=$?
    case $rc in
      0) echo "   $app: no diff" ;;
      1) echo "   $app: DIFF ($(grep -c '^[<>]' "$STATE/diff-$app.txt") lines) -> ${STATE#"$REPO_ROOT"/}/diff-$app.txt" ;;
      *) echo "   $app: ERROR -> ${STATE#"$REPO_ROOT"/}/diff-$app.txt" ;;
    esac
  done
  log "Review the diff files. Expected: Argo CD tracking annotations, removed Flux labels, intended changes only"
}

phase_sync() {
  local wave=${ARGS[0]:?usage: sync <wave>} app
  require argocd kubectl
  local apps
  apps=$(apps_in_wave "$wave" | tr '\n' ' ')
  confirm "Sync wave $wave ($apps) and re-enable auto-sync?"
  for app in $apps; do
    if [[ "$APPLY" == "true" ]]; then
      argocd_core app sync "$app" --server-side --timeout 600
    else
      printf '   [dry-run] argocd --core app sync %s --server-side\n' "$app"
    fi
    run kubectl -n "$ARGO_NS" patch application "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  done
  [[ "$APPLY" == "true" ]] && verify_pvc_uids
  log "Wave $wave adopted"
}

# ── verify / cleanup ────────────────────────────────────────────────────────

# Every PVC recorded at precheck must still exist with the same UID and volume.
# New PVCs (volsync movers, caches) are fine.
verify_pvc_uids() {
  [[ -f "$STATE/pvc-uids.txt" ]] || { warn "no PVC snapshot"; return 0; }
  local now changed
  now=$(kubectl get pvc -A -o json |
    jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(.metadata.uid) \(.spec.volumeName)"' | sort)
  changed=$(comm -23 "$STATE/pvc-uids.txt" <(echo "$now") || true)
  if [[ -n "$changed" ]]; then
    echo "$changed" | tee "$STATE/pvc-diff.txt"
    die "recorded PVCs deleted/recreated (above) - STOP and investigate before continuing"
  fi
  log "All $(wc -l < "$STATE/pvc-uids.txt" | tr -d ' ') recorded PVCs unchanged"
}

phase_verify() {
  verify_pvc_uids
  local bad
  bad=$(kubectl -n "$ARGO_NS" get applications -o json | jq -r '.items[]
    | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
    | "   \(.metadata.name): \(.status.sync.status)/\(.status.health.status)"')
  if [[ -z "$bad" ]]; then log "All Applications Synced & Healthy"; else echo "$bad"; warn "Applications not Synced/Healthy"; fi
  local manual
  manual=$(kubectl get replicationsources -A -o json | jq '[.items[] | select(.spec.trigger.schedule == null)] | length')
  if [[ "$manual" == "0" ]]; then log "All ReplicationSources have a schedule"; else warn "$manual ReplicationSources without schedule"; fi
  if [[ "$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed)" == "false" ]]; then
    log "Vault unsealed"
  else
    warn "Vault sealed/unreachable"
  fi
}

phase_cleanup() {
  verify_pvc_uids
  log "Remove Helm release secrets (Argo CD renders with helm template; releases are now orphaned metadata)"
  confirm "Delete $(wc -l < "$STATE/helm-release-secrets.txt" | tr -d ' ') Helm release secrets and the flux-system namespace?"
  local ns _rel secret
  while read -r ns _rel secret; do
    run kubectl -n "$ns" delete secret "$secret"
  done < <(kubectl get secrets -A -l owner=helm -o json |
             jq -r '.items[] | "\(.metadata.namespace) \(.metadata.labels.name) \(.metadata.name)"')
  run kubectl delete namespace flux-system --ignore-not-found
  log "Cleanup done. Remaining manual steps: see docs/argocd-cutover.md (webhook, Flux labels, mise)"
}

main() {
  parse_flags "$@"
  case "$PHASE" in
    precheck) phase_precheck ;;
    backup) phase_backup ;;
    install-argo) phase_install_argo ;;
    freeze-flux) phase_freeze_flux ;;
    adopt) phase_adopt ;;
    diff) phase_diff ;;
    sync) phase_sync ;;
    verify) phase_verify ;;
    cleanup) phase_cleanup ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
  esac
  [[ "$APPLY" == "true" || "$PHASE" =~ ^(precheck|diff|verify)$ ]] || echo "(dry-run: re-run with --apply to execute)"
}

main "$@"
