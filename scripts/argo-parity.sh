#!/usr/bin/env bash
# argo-parity.sh - Render converted Argo CD Applications exactly like the repo-server
# (helm-secrets wrapper + kustomize/ksops) and diff against the Flux baseline
# produced by scripts/render-flux-baseline.sh.
# Usage: ./argo-parity.sh [--render-only] [namespace ...]   (default: every namespace)
#   --render-only: no Flux baseline; render every Application and validate with
#                  kubeconform (used by CI). Rendered output is never printed.
# Output: .tmp/parity/<ns>/<app>.diff + summary; exit 1 if any app differs or fails.

set -Eeuo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=scripts/render-flux-baseline.sh
source "$REPO_ROOT/scripts/render-flux-baseline.sh"   # normalise(), load_domain()

BASELINE=$REPO_ROOT/.tmp/baseline
PARITY=$REPO_ROOT/.tmp/parity
TOOLS=$REPO_ROOT/.tmp/tools
KSOPS_VERSION=4.5.1
HELM_SECRETS_VERSION=4.7.10
FLUX_KINDS='["HelmRelease","OCIRepository","HelmRepository","Kustomization"]'
RESULTS=()
RENDER_ONLY=false
KUBECONFORM_ARGS=(-strict -ignore-missing-schemas -summary
  -skip "Gateway,HTTPRoute,Secret,TalosUpgrade,KubernetesUpgrade"
  -schema-location default
  -schema-location "https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

install_tools() {
  local os arch p
  os=$(uname -s); arch=$(uname -m | sed 's/aarch64/arm64/')
  mkdir -p "$TOOLS/helm-plugins"
  [[ -x "$TOOLS/ksops" ]] || curl -fsSL \
    "https://github.com/viaduct-ai/kustomize-sops/releases/download/v$KSOPS_VERSION/ksops_${KSOPS_VERSION}_${os}_${arch}.tar.gz" |
    tar -C "$TOOLS" -xzf - ksops
  for p in secrets secrets-getter secrets-post-renderer; do
    [[ -d "$TOOLS/helm-plugins/$p" ]] || curl -fsSL \
      "https://github.com/jkroepke/helm-secrets/releases/download/v$HELM_SECRETS_VERSION/$p-$HELM_SECRETS_VERSION.tgz" |
      tar -C "$TOOLS/helm-plugins" -xzf -
  done
  export PATH="$TOOLS:$PATH" HELM_PLUGINS="$TOOLS/helm-plugins"
  export HELM_SECRETS_WRAPPER_ENABLED=true HELM_SECRETS_BACKEND=sops HELM_SECRETS_HELM_PATH
  export HELM_SECRETS_VALUES_ALLOW_ABSOLUTE_PATH=true HELM_SECRETS_DECRYPT_SECRETS_IN_TMP_DIR=true
  HELM_SECRETS_HELM_PATH=$(command -v helm)
  export HELM_REPOSITORY_CONFIG="$WORK/helm-repos.yaml" HELM_REPOSITORY_CACHE="$TOOLS/helm-cache"
  : > "$HELM_REPOSITORY_CONFIG"
}

# Render the chart source of an Application (yaml on stdin) to stdout
render_chart() {
  local app repo chart version release ns args=() f
  app=$(cat)
  chart=$(yq '.spec.sources[] | select(has("chart")) | .chart' <<<"$app")
  [[ -n "$chart" ]] || return 0
  repo=$(yq '.spec.sources[] | select(has("chart")) | .repoURL' <<<"$app")
  version=$(yq '.spec.sources[] | select(has("chart")) | .targetRevision' <<<"$app")
  release=$(yq '.spec.sources[] | select(has("chart")) | .helm.releaseName' <<<"$app")
  ns=$(yq '.spec.destination.namespace' <<<"$app")
  if [[ "$repo" == http* ]]; then args+=("$chart" --repo "$repo"); else args+=("oci://$repo/$chart"); fi
  while IFS= read -r f; do
    args+=(-f "$REPO_ROOT/${f#\$repo/}")
  done < <(yq '.spec.sources[] | select(has("chart")) | .helm.valueFiles[]' <<<"$app")
  "$HELM_PLUGINS/secrets/scripts/wrapper/helm.sh" template "$release" "${args[@]}" \
    --version "$version" --namespace "$ns" --include-crds 2>"$WORK/helm.err" ||
    { grep -v '^\[helm-secrets\]' "$WORK/helm.err" >&2; return 1; }
}

# Render the git path source (kustomize + ksops) of an Application to stdout
render_path() {
  local path
  path=$(yq '(.spec.sources // [.spec.source])[] | select(has("path")) | .path' <<<"$1")
  [[ -n "$path" ]] || return 0
  kustomize build --enable-alpha-plugins --enable-exec --enable-helm \
    --load-restrictor LoadRestrictionsNone "$REPO_ROOT/$path"
}

# Flux side: every baseline dir of this app (main + -backup), Flux CRs removed
baseline_for() {
  local ns=$1 name=$2 d files=()
  for d in "$BASELINE/$ns/$name" "$BASELINE/$ns/$name-backup"; do
    if [[ -d "$d" ]]; then files+=("$d"/*.yaml); fi
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  yq ea "select(.kind as \$k | $FLUX_KINDS | contains([\$k]) | not)" "${files[@]}"
}

# Changed lines in a unified diff, excluding the two file headers
diff_lines() { tail -n +3 "$1" | grep -c '^[-+]' || true; }

check_app() {
  local file=$1 ns name app out
  ns=$(basename "$(dirname "$file")"); name=$(basename "$file" .yaml)
  out="$PARITY/$ns"; mkdir -p "$out"
  app=$(cat "$file")
  if ! { render_chart <<<"$app"; echo "---"; render_path "$app"; } > "$WORK/argo.raw" 2>"$WORK/err"; then
    RESULTS+=("FAIL  $ns/$name: $(tail -1 "$WORK/err")"); return 0
  fi
  normalise < "$WORK/argo.raw" > "$out/$name.argo.yaml"
  if [[ "$RENDER_ONLY" == "true" ]]; then
    if kubeconform "${KUBECONFORM_ARGS[@]}" "$out/$name.argo.yaml" > "$WORK/kc" 2>&1; then
      RESULTS+=("OK    $ns/$name")
    else  # only the summary/error lines, never the manifests
      RESULTS+=("FAIL  $ns/$name: $(grep -m1 -E 'is invalid|error' "$WORK/kc" | cut -c1-200)")
    fi
    return 0
  fi
  baseline_for "$ns" "$name" | normalise > "$out/$name.flux.yaml"
  if diff -u "$out/$name.flux.yaml" "$out/$name.argo.yaml" > "$out/$name.diff"; then
    RESULTS+=("OK    $ns/$name"); rm "$out/$name.diff"
  else
    RESULTS+=("DIFF  $ns/$name ($(diff_lines "$out/$name.diff") lines) -> ${out#"$REPO_ROOT"/}/$name.diff")
  fi
}

parity_main() {
  if [[ "${1:-}" == "--render-only" ]]; then RENDER_ONLY=true; shift; fi
  [[ "$RENDER_ONLY" == "true" || -d "$BASELINE" ]] || { echo "Run scripts/render-flux-baseline.sh first"; exit 1; }
  install_tools
  local namespaces=("$@") ns file
  if [[ ${#namespaces[@]} -eq 0 ]]; then
    mapfile -t namespaces < <(find "$REPO_ROOT/kubernetes/argo/apps" -mindepth 1 -maxdepth 1 -type d \
      -exec basename {} \; | sort)
  fi
  for ns in "${namespaces[@]}"; do
    for file in "$REPO_ROOT/kubernetes/argo/apps/$ns"/*.yaml; do
      [[ -e "$file" ]] && check_app "$file"
    done
  done
  mkdir -p "$PARITY"
  printf '%s\n' "${RESULTS[@]}" | tee "$PARITY/SUMMARY.txt"
  ! printf '%s\n' "${RESULTS[@]}" | grep -qv '^OK'
}

parity_main "$@"
