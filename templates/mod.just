set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT     := source_directory() + "/.."
TEMPLATE_DIR  := source_directory()
BOOTSTRAP_DIR := REPO_ROOT + "/bootstrap"
KUBERNETES_DIR := REPO_ROOT + "/kubernetes"
TALOS_DIR     := REPO_ROOT + "/talos"

# Initialise cluster configuration from cluster.sample.toml
init:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f "{{REPO_ROOT}}/cluster.toml" ]]; then
        cp "{{REPO_ROOT}}/cluster.sample.toml" "{{REPO_ROOT}}/cluster.toml"
        echo "✓ Created cluster.toml — fill in your values then run 'just configure'"
    else
        echo "cluster.toml already exists, skipping"
    fi
    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        age-keygen --output "$SOPS_AGE_KEY_FILE"
        echo "✓ Generated age key at $SOPS_AGE_KEY_FILE"
    fi
    if [[ ! -f "{{REPO_ROOT}}/github-deploy.key" ]]; then
        ssh-keygen -t ed25519 -C "deploy-key" -f "{{REPO_ROOT}}/github-deploy.key" -q -P ""
        echo "✓ Generated SSH deploy key"
    fi
    if [[ ! -f "{{REPO_ROOT}}/github-push-token.txt" ]]; then
        python3 -c "import secrets; print(secrets.token_hex(16))" > "{{REPO_ROOT}}/github-push-token.txt"
        echo "✓ Generated GitHub push token"
    fi

# Render and validate all configuration files
configure:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f "{{REPO_ROOT}}/cluster.toml" ]]; then
        echo "Error: cluster.toml not found. Run 'just init' first." >&2
        exit 1
    fi
    if [[ ! -f "{{REPO_ROOT}}/cloudflare-tunnel.json" ]]; then
        echo "Error: cloudflare-tunnel.json not found. See README." >&2
        exit 1
    fi

    echo "==> Validating cluster.toml..."
    cd "{{REPO_ROOT}}" && uv run python templates/scripts/validate.py cluster.toml

    echo "==> Rendering templates..."
    cd "{{REPO_ROOT}}" && PYTHONDONTWRITEBYTECODE=1 uv run makejinja

    echo "==> Encrypting secrets..."
    while IFS= read -r -d '' secret_file; do
        if [[ "$(sops filestatus "$secret_file" | jq -r ".encrypted")" == "false" ]]; then
            sops --encrypt --in-place "$secret_file"
            echo "  ✓ Encrypted $secret_file"
        fi
    done < <(find "{{BOOTSTRAP_DIR}}" "{{KUBERNETES_DIR}}" "{{TALOS_DIR}}" -type f -name "*.sops.*" -print0 2>/dev/null)

    echo "==> Validating Kubernetes manifests..."
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
            echo "--- validating $dir"
            kustomize build "$dir" "${kustomize_args[@]}" | kubeconform "${kubeconform_args[@]}"
          done

    echo "==> Validating Talos configuration..."
    VALIDATE_DIR=$(mktemp -d)
    cd "{{TALOS_DIR}}" && topf render --output "$VALIDATE_DIR" && rm -rf "$VALIDATE_DIR"

    echo "✓ configure complete"

# Gather common resources from the cluster for debugging
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
    echo "✓ Template files archived to $TIDY_FOLDER"

# Remove all generated (templated) files and directories
[confirm("Remove all templated files and directories... continue?")]
reset:
    rm -rf "{{BOOTSTRAP_DIR}}"
    rm -rf "{{KUBERNETES_DIR}}"
    rm -rf "{{TALOS_DIR}}"
    rm -f  "{{REPO_ROOT}}/.sops.yaml"
