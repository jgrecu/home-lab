set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT   := source_directory() + "/.."
TALOS_DIR   := REPO_ROOT + "/talos"
SCRIPTS_DIR := REPO_ROOT + "/scripts"

# Bootstrap the Talos cluster from scratch
bootstrap-talos:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{TALOS_DIR}}"
    # Generate secrets bundle if it doesn't exist yet
    if [[ ! -f secrets.sops.yaml ]]; then
        topf secrets --confirm=false
    fi
    # Apply configs to all nodes (handles maintenance mode automatically)
    # --auto-bootstrap bootstraps etcd on the first control-plane after apply
    topf apply --auto-bootstrap --confirm=false
    # Retrieve configs
    topf kubeconfig > "{{REPO_ROOT}}/kubeconfig"
    topf talosconfig > talosconfig

# Bootstrap Flux and Helm apps into a running Talos cluster
bootstrap-apps:
    bash "{{SCRIPTS_DIR}}/bootstrap-apps.sh"
