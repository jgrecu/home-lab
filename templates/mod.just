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
    bash "{{TEMPLATE_DIR}}/scripts/kubeconform.sh" "{{KUBERNETES_DIR}}"
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
    echo "✓ Template files archived to $TIDY_FOLDER"

# Remove all generated (templated) files and directories
[confirm("Remove all templated files and directories... continue?")]
reset:
    rm -rf "{{BOOTSTRAP_DIR}}"
    rm -rf "{{KUBERNETES_DIR}}"
    rm -rf "{{TALOS_DIR}}"
    rm -f  "{{REPO_ROOT}}/.sops.yaml"

# [private] Render Jinja2 templates into kubernetes/ bootstrap/ talos/
[private]
_render-configs:
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
    cd "{{REPO_ROOT}}" && PYTHONDONTWRITEBYTECODE=1 uv run makejinja

# [private] Encrypt any unencrypted *.sops.* files with SOPS
[private]
_encrypt-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r -d '' secret_file; do
        if [[ "$(sops filestatus "$secret_file" | jq -r ".encrypted")" == "false" ]]; then
            sops --encrypt --in-place "$secret_file"
            echo "✓ Encrypted $secret_file"
        fi
    done < <(find "{{BOOTSTRAP_DIR}}" "{{KUBERNETES_DIR}}" "{{TALOS_DIR}}" -type f -name "*.sops.*" -print0 2>/dev/null)

# [private] Validate Kubernetes manifests with kubeconform
[private]
_validate-kubernetes:
    bash "{{TEMPLATE_DIR}}/scripts/kubeconform.sh" "{{KUBERNETES_DIR}}"

# [private] Validate Talos configuration with talhelper
[private]
_validate-talos:
    talhelper validate talconfig "{{TALOS_DIR}}/talconfig.yaml"
