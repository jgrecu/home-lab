set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT  := source_directory() + "/.."
TALOS_DIR  := source_directory()

# Generate Talos machine configuration files (offline, to talos/output/)
render:
    cd "{{TALOS_DIR}}" && topf render --output ./output

# Show pending config changes without applying (dry-run diff)
diff:
    cd "{{TALOS_DIR}}" && topf apply --dry-run

# Apply Talos config to all nodes
apply MODE="auto":
    cd "{{TALOS_DIR}}" && topf apply --mode "{{MODE}}"

# Apply Talos config to a single node (usage: just talos apply-node m900-ctrl)
apply-node NODE MODE="auto":
    cd "{{TALOS_DIR}}" && topf apply --nodes-filter "^{{NODE}}$" --mode "{{MODE}}"

# Upgrade Talos on all nodes to the version in talos/topf.yaml
upgrade:
    cd "{{TALOS_DIR}}" && topf upgrade

# Upgrade Talos on a single node (usage: just talos upgrade-node m900-ctrl)
upgrade-node NODE:
    cd "{{TALOS_DIR}}" && topf upgrade --nodes-filter "^{{NODE}}$"

# List all nodes and their current state (version, stage, schematic)
nodes:
    cd "{{TALOS_DIR}}" && topf nodes

# Regenerate kubeconfig from the live cluster
kubeconfig:
    cd "{{TALOS_DIR}}" && topf kubeconfig > "{{REPO_ROOT}}/kubeconfig"

# Regenerate talosconfig from the secrets bundle
talosconfig:
    cd "{{TALOS_DIR}}" && topf talosconfig > talosconfig

# Reset all nodes back to maintenance mode (destroys cluster state)
[confirm("This will destroy your cluster and reset nodes to maintenance mode... continue?")]
reset:
    cd "{{TALOS_DIR}}" && topf reset
