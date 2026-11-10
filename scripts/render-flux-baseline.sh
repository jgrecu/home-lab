#!/usr/bin/env bash
# render-flux-baseline.sh - Render the current Flux desired state for a later
# parity diff against the Argo CD rendering.
# Usage: ./render-flux-baseline.sh [out-dir]   (default: .tmp/baseline)
#
# - kustomize build of every Flux Kustomization (ks.yaml, backup-ks.yaml, *-ks.yaml)
#   with Flux behaviour: ${SECRET_DOMAIN} substitution, $${ -> ${ un-escape,
#   targetNamespace override
# - helm template of every HelmRelease found in those builds (CRDs included)
# - Secret values are NEVER written: only key names with "<redacted>"
# Output is normalised (sorted docs, sorted keys) for stable diffs.

set -Eeuo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
OUT=${1:-$REPO_ROOT/.tmp/baseline}
WORK=$(mktemp -d)
FAILURES=()
KS_COUNT=0
HR_COUNT=0
POST_RENDERERS=()

CLUSTER_SCOPED='["Namespace","ClusterRole","ClusterRoleBinding","CustomResourceDefinition",
  "StorageClass","ClusterIssuer","PriorityClass","ValidatingWebhookConfiguration",
  "MutatingWebhookConfiguration","VolumeSnapshotClass","PersistentVolume","GatewayClass",
  "ClusterSecretStore","APIService","CSIDriver","IngressClass","RuntimeClass"]'

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log() { echo "==> $*"; }
fail() { FAILURES+=("$1: $2"); echo "    FAIL $1: $2" >&2; }

load_domain() {
  SECRET_DOMAIN=$(sops -d "$REPO_ROOT/kubernetes/components/sops/cluster-secrets.sops.yaml" |
    yq '.stringData.SECRET_DOMAIN')
  [[ -n "$SECRET_DOMAIN" && "$SECRET_DOMAIN" != "null" ]] || { echo "Cannot read SECRET_DOMAIN"; exit 1; }
}

# Flux postBuild behaviour: substitute ${SECRET_DOMAIN}, then un-escape $${ -> ${
flux_substitute() {
  sed -e "s|\${SECRET_DOMAIN}|$SECRET_DOMAIN|g" -e 's|\$\${|${|g'
}

# Replace Secret values by "<redacted>" and normalise: sorted keys, sorted docs
# shellcheck disable=SC2016  # yq variables, not shell
normalise() {
  yq ea -P '[select(. != null)]
    | map(select(.kind == "Secret") |= (
        (.data // {} | keys) as $d | (.stringData // {} | keys) as $s
        | del(.data, .stringData, .sops)
        | .data = ($d + $s | map({(.): "<redacted>"}) | .[] as $i ireduce ({}; . * $i))))
    | sort_by(.kind, .metadata.namespace // "", .metadata.name)
    | .[] | sort_keys(..) | split_doc'
}

# Prints "name<TAB>path<TAB>targetNamespace" for every Kustomization doc in a ks file
list_ks_docs() {
  yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*")
    | [.metadata.name, .spec.path, (.spec.targetNamespace // "")] | @tsv' "$1"
}

set_target_namespace() {
  local ns=$1
  if [[ -z "$ns" ]]; then cat; return; fi
  yq ea "select(.kind as \$k | $CLUSTER_SCOPED | contains([\$k]) | not).metadata.namespace = \"$ns\""
}

build_ks() {
  local ns_dir=$1 name=$2 path=$3 target_ns=$4 dest
  dest="$WORK/ks/$ns_dir/$name"
  mkdir -p "$dest"
  if ! kustomize build --load-restrictor LoadRestrictionsNone "$REPO_ROOT/${path#./}" 2>"$dest/err" | flux_substitute |
      set_target_namespace "$target_ns" > "$dest/raw.yaml"; then
    fail "ks $ns_dir/$name" "$(tail -1 "$dest/err")"
    return 0
  fi
  KS_COUNT=$((KS_COUNT + 1))
}

build_all_ks() {
  local file ns_dir name path target_ns
  while IFS= read -r file; do
    ns_dir=$(cut -d/ -f3 <<<"${file#"$REPO_ROOT"/}")
    while IFS=$'\t' read -r name path target_ns; do
      [[ -n "$name" ]] && build_ks "$ns_dir" "$name" "$path" "$target_ns"
    done < <(list_ks_docs "$file")
  done < <(find "$REPO_ROOT/kubernetes/apps" -name '*ks.yaml' | sort)
}

# All chart sources across every build: "kind/namespace/name<TAB>url<TAB>tag<TAB>type"
index_sources() {
  find "$WORK/ks" -name raw.yaml -exec yq -N 'select(.kind == "OCIRepository" or .kind == "HelmRepository")
      | [.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name, .spec.url,
         (.spec.ref.tag // ""), (.spec.type // "default")] | @tsv' {} + > "$WORK/sources.tsv"
}

source_field() { awk -F'\t' -v k="$1" -v c="$2" '$1 == k { print $c; exit }' "$WORK/sources.tsv"; }

# Prints helm args "<chart> --version <v> [--repo <url>]" for a HelmRelease (yaml on stdin)
chart_args() {
  local hr ns kind name url tag chart version type
  hr=$(cat); ns=$(yq '.metadata.namespace' <<<"$hr")
  if [[ "$(yq '.spec.chartRef.kind // ""' <<<"$hr")" == "OCIRepository" ]]; then
    name=$(yq '.spec.chartRef.name' <<<"$hr")
    url=$(source_field "OCIRepository/$ns/$name" 2); tag=$(source_field "OCIRepository/$ns/$name" 3)
    [[ -n "$url" ]] || return 1
    echo "$url --version $tag"; return 0
  fi
  kind=$(yq '.spec.chart.spec.sourceRef.kind' <<<"$hr")
  name=$(yq '.spec.chart.spec.sourceRef.name' <<<"$hr")
  ns=$(yq ".spec.chart.spec.sourceRef.namespace // \"$ns\"" <<<"$hr")
  chart=$(yq '.spec.chart.spec.chart' <<<"$hr"); version=$(yq '.spec.chart.spec.version' <<<"$hr")
  url=$(source_field "$kind/$ns/$name" 2); type=$(source_field "$kind/$ns/$name" 4)
  [[ -n "$url" ]] || return 1
  if [[ "$type" == "oci" || "$url" == oci://* ]]; then
    echo "${url%/}/$chart --version $version"
  else
    echo "$chart --repo $url --version $version"
  fi
}

render_helmrelease() {
  local dir=$1 hr=$2 name ns args values
  name=$(yq '.metadata.name' <<<"$hr"); ns=$(yq '.metadata.namespace' <<<"$hr")
  [[ "$(yq '.spec.postRenderers // [] | length' <<<"$hr")" == "0" ]] || POST_RENDERERS+=("$ns/$name")
  if ! args=$(chart_args <<<"$hr"); then
    fail "hr $ns/$name" "chart source not found"; return 0
  fi
  values="$WORK/values-$ns-$name.yaml"
  yq '.spec.values // {}' <<<"$hr" > "$values"
  # shellcheck disable=SC2086  # args is a word list built by chart_args
  if helm template "$name" $args --namespace "$ns" --include-crds -f "$values" \
      >"$dir/helm-$name.raw.yaml" 2>"$dir/helm-$name.err"; then
    HR_COUNT=$((HR_COUNT + 1))
  else
    fail "hr $ns/$name" "$(grep -m1 -i error "$dir/helm-$name.err" || tail -1 "$dir/helm-$name.err")"
  fi
  rm -f "$values"
}

render_all_helmreleases() {
  local raw dir idx count
  while IFS= read -r raw; do
    dir=$(dirname "$raw")
    count=$(yq ea -N 'select(.kind == "HelmRelease") | .metadata.name' "$raw" | grep -c . || true)
    for ((idx = 0; idx < count; idx++)); do
      render_helmrelease "$dir" "$(yq ea "[select(.kind == \"HelmRelease\")] | .[$idx]" "$raw")"
    done
  done < <(find "$WORK/ks" -name raw.yaml | sort)
}

write_output() {
  local raw rel f
  rm -rf "$OUT"; mkdir -p "$OUT"
  while IFS= read -r raw; do
    rel=${raw#"$WORK/ks/"}; rel=$(dirname "$rel")
    mkdir -p "$OUT/$rel"
    normalise < "$raw" > "$OUT/$rel/kustomize.yaml"
    for f in "$(dirname "$raw")"/helm-*.raw.yaml; do
      [[ -e "$f" ]] || continue
      normalise < "$f" > "$OUT/$rel/$(basename "${f%.raw.yaml}").yaml"
    done
  done < <(find "$WORK/ks" -name raw.yaml | sort)
}

write_summary() {
  {
    echo "Flux baseline rendered $(date -u +%FT%TZ) from $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    echo "Kustomizations rendered: $KS_COUNT"
    echo "HelmReleases rendered:   $HR_COUNT"
    echo "postRenderers NOT applied (patch manually when diffing): ${POST_RENDERERS[*]:-none}"
    echo "Failures: ${#FAILURES[@]}"
    printf '  %s\n' "${FAILURES[@]}"
  } | tee "$OUT/SUMMARY.txt"
}

main() {
  local tool
  for tool in kustomize helm yq sops git; do command -v "$tool" &>/dev/null || { echo "$tool not found"; exit 1; }; done
  load_domain
  # Isolate helm from the user's repo list/cache (stale repos break `helm template --repo`)
  export HELM_REPOSITORY_CONFIG="$WORK/helm-repos.yaml" HELM_REPOSITORY_CACHE="$WORK/helm-cache"
  : > "$HELM_REPOSITORY_CONFIG"
  log "Building Flux Kustomizations"; build_all_ks
  index_sources
  log "Rendering HelmReleases"; render_all_helmreleases
  log "Writing normalised output to $OUT"; write_output
  write_summary
  [[ ${#FAILURES[@]} -eq 0 ]]
}

main "$@"
