set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT      := source_directory() + "/.."
TEMPLATE_DIR   := source_directory()
BOOTSTRAP_DIR  := REPO_ROOT + "/bootstrap"
KUBERNETES_DIR := REPO_ROOT + "/kubernetes"
TALOS_DIR      := REPO_ROOT + "/talos"

# ─── User-facing recipes ──────────────────────────────────────────────────────

# Check that all required files exist and cluster.toml validates against the schema
[doc("Pre-flight check — verify required files and validate cluster.toml")]
[no-exit-message]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    just log info "just version" version "{{just_version()}}"
    just template doctor-check "cluster.toml"          "{{REPO_ROOT}}/cluster.toml"             || rc=1
    just template doctor-check "cluster.sample.toml"   "{{REPO_ROOT}}/cluster.sample.toml"      || rc=1
    just template doctor-check "cloudflare-tunnel.json" "{{REPO_ROOT}}/cloudflare-tunnel.json"   || rc=1
    just template doctor-check "age.key"               "$SOPS_AGE_KEY_FILE"                     || rc=1
    just template doctor-check "github-deploy.key"     "{{REPO_ROOT}}/github-deploy.key"        || rc=1
    just template doctor-check "github-push-token.txt" "{{REPO_ROOT}}/github-push-token.txt"    || rc=1
    just template doctor-check "templates/"            "{{TEMPLATE_DIR}}"                       || rc=1
    just template doctor-check "makejinja.toml"        "{{REPO_ROOT}}/makejinja.toml"           || rc=1
    just template doctor-check "validate.py"           "{{TEMPLATE_DIR}}/scripts/validate.py"   || rc=1
    just template doctor-check "cluster.schema.json"   "{{REPO_ROOT}}/cluster.schema.json"      || rc=1
    if [[ -f "{{REPO_ROOT}}/cluster.toml" && -f "{{TEMPLATE_DIR}}/scripts/validate.py" ]]; then
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
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f "{{REPO_ROOT}}/cluster.toml" ]]; then
        cp "{{REPO_ROOT}}/cluster.sample.toml" "{{REPO_ROOT}}/cluster.toml"
        just log info "created" file cluster.toml
    else
        just log info "exists" file cluster.toml
    fi
    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        age-keygen --output "$SOPS_AGE_KEY_FILE"
        just log info "created" file age.key
    fi
    if [[ ! -f "{{REPO_ROOT}}/github-deploy.key" ]]; then
        ssh-keygen -t ed25519 -C "deploy-key" -f "{{REPO_ROOT}}/github-deploy.key" -q -P ""
        just log info "created" file github-deploy.key
    fi
    if [[ ! -f "{{REPO_ROOT}}/github-push-token.txt" ]]; then
        python3 -c "import secrets; print(secrets.token_hex(16))" > "{{REPO_ROOT}}/github-push-token.txt"
        just log info "created" file github-push-token.txt
    fi

# Render and validate all configuration files
[doc("Render templates, encrypt secrets, validate Kubernetes manifests and Talos config")]
configure:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f "{{REPO_ROOT}}/cluster.toml" ]]; then
        just log error "cluster.toml not found — run 'just init' first"
        exit 1
    fi
    if [[ ! -f "{{REPO_ROOT}}/cloudflare-tunnel.json" ]]; then
        just log error "cloudflare-tunnel.json not found — see README"
        exit 1
    fi

    just log info "validating" file cluster.toml
    cd "{{REPO_ROOT}}" && uv run python templates/scripts/validate.py cluster.toml

    just log info "rendering" step templates
    cd "{{REPO_ROOT}}" && PYTHONDONTWRITEBYTECODE=1 uv run makejinja

    just log info "encrypting" step secrets
    find "{{BOOTSTRAP_DIR}}" "{{KUBERNETES_DIR}}" "{{TALOS_DIR}}" -type f -name '*.sops.*' -print0 \
        | while IFS= read -r -d '' f; do
            if [[ "$(sops filestatus "$f" | jq -r ".encrypted")" == "false" ]]; then
                sops --encrypt --in-place "$f"
                echo "  ✓ Encrypted $f"
            fi
          done

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

    just log info "validating" step "talos configuration"
    VALIDATE_DIR=$(mktemp -d)
    cd "{{TALOS_DIR}}" && topf render --output "$VALIDATE_DIR" && rm -rf "$VALIDATE_DIR"

    just log info "done" step configure

# Regenerate cluster.schema.json from the Pydantic validator
[doc("Regenerate cluster.schema.json (run after adding fields to validate.py)")]
schema:
    cd "{{REPO_ROOT}}" && uv run python templates/scripts/validate.py --schema > cluster.schema.json
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
    TIDY_FOLDER="{{REPO_ROOT}}/.private/$(date +%s)"
    mkdir -p "$TIDY_FOLDER"
    gsed -i 's/(\.\.j2)\?//g' "{{REPO_ROOT}}/.renovaterc.json5" 2>/dev/null || \
        sed -i 's/(\.\.j2)\?//g' "{{REPO_ROOT}}/.renovaterc.json5"
    mv "{{TEMPLATE_DIR}}" "$TIDY_FOLDER/templates"
    mv "{{REPO_ROOT}}/makejinja.toml" "$TIDY_FOLDER/makejinja.toml"
    mv "{{REPO_ROOT}}/pyproject.toml" "$TIDY_FOLDER/pyproject.toml"
    mv "{{REPO_ROOT}}/uv.lock" "$TIDY_FOLDER/uv.lock"
    mv "{{REPO_ROOT}}/cluster.toml" "$TIDY_FOLDER/cluster.toml"
    mv "{{REPO_ROOT}}/cluster.sample.toml" "$TIDY_FOLDER/cluster.sample.toml"
    mv "{{REPO_ROOT}}/cluster.schema.json" "$TIDY_FOLDER/cluster.schema.json" 2>/dev/null || true
    just log info "archived" path "$TIDY_FOLDER"

# Remove all generated (templated) files and directories
[confirm("Remove all templated files and directories... continue?")]
[doc("Delete bootstrap/, kubernetes/, talos/ and .sops.yaml")]
reset:
    rm -rf "{{BOOTSTRAP_DIR}}"
    rm -rf "{{KUBERNETES_DIR}}"
    rm -rf "{{TALOS_DIR}}"
    rm -f  "{{REPO_ROOT}}/.sops.yaml"

# ─── Private helpers ──────────────────────────────────────────────────────────

# Validate cluster.toml and exit non-zero if invalid
[private]
config-json:
    cd "{{REPO_ROOT}}" && uv run --quiet python templates/scripts/validate.py cluster.toml

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
