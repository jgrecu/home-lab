set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

BOOTSTRAP_DIR  := "bootstrap"
KUBERNETES_DIR := "kubernetes"
TALOS_DIR      := "talos"
TEMPLATE_DIR   := source_directory()

# ─── User-facing recipes ──────────────────────────────────────────────────────

# Check that all required files exist and cluster.toml validates against the schema
[doc("Pre-flight check — verify required files and validate cluster.toml")]
[no-exit-message]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    just log info "just version" version "{{just_version()}}"
    just template doctor-check "cluster.toml"          cluster.toml                        || rc=1
    just template doctor-check "cluster.sample.toml"   cluster.sample.toml                 || rc=1
    just template doctor-check "cloudflare-tunnel.json" cloudflare-tunnel.json             || rc=1
    just template doctor-check "age.key"               "$SOPS_AGE_KEY_FILE"                || rc=1
    just template doctor-check "github-deploy.key"     github-deploy.key                   || rc=1
    just template doctor-check "github-push-token.txt" github-push-token.txt               || rc=1
    just template doctor-check "templates/"            "{{TEMPLATE_DIR}}"                  || rc=1
    just template doctor-check "makejinja.toml"        makejinja.toml                      || rc=1
    just template doctor-check "validate.py"           "{{TEMPLATE_DIR}}/scripts/validate.py" || rc=1
    just template doctor-check "cluster.schema.json"   cluster.schema.json                 || rc=1
    if [[ -f cluster.toml && -f "{{TEMPLATE_DIR}}/scripts/validate.py" ]]; then
        if just template config-json &>/dev/null; then
            just log info "ok" check schema
        else
            just log error "fail" check schema
            just log info "diagnose with: uv run python templates/scripts/validate.py cluster.toml"
            rc=1
        fi
    fi
    [[ "$rc" == 0 ]] && just log info "all good"
    exit "$rc"

# Initialise cluster configuration from cluster.sample.toml
[doc("Create cluster.toml, age key, deploy key, and push token")]
init:
    [ -f cluster.toml ]          || cp cluster.sample.toml cluster.toml
    [ -f "$SOPS_AGE_KEY_FILE" ]  || age-keygen -pq --output "$SOPS_AGE_KEY_FILE"
    [ -f github-deploy.key ]     || ssh-keygen -t ed25519 -C "deploy-key" -f github-deploy.key -q -P ""
    [ -f github-push-token.txt ] || python3 -c "import secrets; print(secrets.token_hex(16))" > github-push-token.txt

# Render and validate all configuration files
[doc("Render templates, encrypt secrets, validate Kubernetes manifests and Talos config")]
configure: render encrypt-secrets validate-kubernetes validate-talos

# Regenerate cluster.schema.json from the Pydantic validator
[doc("Regenerate cluster.schema.json (run after adding fields to validate.py)")]
schema:
    uv run python templates/scripts/validate.py --schema > cluster.schema.json
    just log info "regenerated" file cluster.schema.json

# Gather common resources from the cluster for debugging
[doc("List certificates, HelmReleases, Kustomizations, nodes, pods across all namespaces")]
debug:
    #!/usr/bin/env bash
    set -euo pipefail
    for resource in certificates certificaterequests gitrepositories helmrepositories helmreleases httproutes kustomizations nodes pods; do
        echo "=== $resource ==="
        kubectl get --all-namespaces "$resource" || true
        echo ""
    done

# Archive all template-related files after initial cluster setup is complete
[confirm("All template-related config will be archived... continue?")]
[doc("One-way archive of template tooling under .private/<ts>/ (run after configure works)")]
tidy:
    #!/usr/bin/env bash
    set -euo pipefail
    TIDY_FOLDER=".private/$(date +%s)"
    mkdir -p "$TIDY_FOLDER"
    gsed -i 's/(\.\.j2)\?//g' .renovaterc.json5 2>/dev/null || \
        sed -i 's/(\.\.j2)\?//g' .renovaterc.json5
    mv "{{TEMPLATE_DIR}}" "$TIDY_FOLDER/templates"
    mv makejinja.toml pyproject.toml uv.lock cluster.toml cluster.sample.toml "$TIDY_FOLDER/"
    mv cluster.schema.json "$TIDY_FOLDER/" 2>/dev/null || true
    just log info "archived" path "$TIDY_FOLDER"

# Remove all generated (templated) files and directories
[confirm("Remove all templated files and directories... continue?")]
[doc("Delete bootstrap/, kubernetes/, talos/ and .sops.yaml")]
reset:
    rm -rf "{{BOOTSTRAP_DIR}}" "{{KUBERNETES_DIR}}" "{{TALOS_DIR}}" .sops.yaml

# ─── Private sub-recipes (called as configure dependencies) ───────────────────

# Validate cluster.toml and render all templates via makejinja
[private]
render:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f cluster.toml ]]; then
        just log error "cluster.toml not found — run 'just init' first"
        exit 1
    fi
    if [[ ! -f cloudflare-tunnel.json ]]; then
        just log error "cloudflare-tunnel.json not found — see README"
        exit 1
    fi
    just log info "validating" file cluster.toml
    uv run python templates/scripts/validate.py cluster.toml
    just log info "rendering" step templates
    PYTHONDONTWRITEBYTECODE=1 uv run makejinja

# Encrypt any unencrypted *.sops.* files in place
[private]
encrypt-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    just log info "encrypting" step secrets
    find "{{BOOTSTRAP_DIR}}" "{{KUBERNETES_DIR}}" "{{TALOS_DIR}}" -type f -name '*.sops.*' -print0 \
        | while IFS= read -r -d '' f; do
            if ! status="$(sops filestatus "$f" | jq -r '.encrypted')"; then
                just log fatal "could not read encryption status" file "$f"
            fi
            case "$status" in
                false) sops encrypt --in-place "$f" ;;
                true)  : ;;
                *)     just log fatal "could not determine encryption status" file "$f" ;;
            esac
          done

# Validate all Kubernetes manifests with kubeconform
[private]
validate-kubernetes:
    #!/usr/bin/env bash
    set -euo pipefail
    just log info "validating" step "kubernetes manifests"
    kubeconform_args=(
        "-strict"
        "-ignore-missing-schemas"
        "-skip" "Gateway,HTTPRoute,Secret,TalosUpgrade,KubernetesUpgrade"
        "-schema-location" "default"
        "-schema-location" "https://kubernetes-schemas.pages.dev/{{{{.Group}}}}/{{{{.ResourceKind}}}}_{{{{.ResourceAPIVersion}}}}.json"
        "-verbose"
    )
    kustomize_args=("--load-restrictor=LoadRestrictionsNone")
    find "{{KUBERNETES_DIR}}/flux" -maxdepth 1 -type f -name '*.yaml' -print0 \
        | while IFS= read -r -d '' f; do kubeconform "${kubeconform_args[@]}" "$f"; done
    find "{{KUBERNETES_DIR}}/flux" "{{KUBERNETES_DIR}}/apps" -type f -name 'kustomization.yaml' -print0 \
        | while IFS= read -r -d '' f; do
            dir="${f%kustomization.yaml}"
            kustomize build "$dir" "${kustomize_args[@]}" | kubeconform "${kubeconform_args[@]}"
          done

# Render all topf machine configs (offline) and verify secrets bundle is encrypted
[private]
[working-directory("talos")]
validate-talos:
    #!/usr/bin/env bash
    set -euo pipefail
    topf render --confirm=false --output "$(mktemp -d)" >/dev/null
    if ! sops filestatus secrets.sops.yaml | jq --exit-status '.encrypted == true' >/dev/null; then
        just log fatal "Talos secrets bundle is not encrypted"
    fi

# ─── Doctor helpers ───────────────────────────────────────────────────────────

# Validate cluster.toml and exit non-zero if invalid
[private]
config-json:
    uv run --quiet python templates/scripts/validate.py cluster.toml

# Check a single file/directory exists; log result
[no-exit-message]
[private]
doctor-check label path:
    #!/usr/bin/env bash
    if [[ -e "{{path}}" ]]; then
        just log info "ok" file "{{label}}"
    else
        just log error "missing" file "{{label}}"
        exit 1
    fi
