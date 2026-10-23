set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT  := source_directory() + "/.."
TALOS_DIR  := source_directory()

# Generate Talos machine configuration files
generate-config:
    cd "{{TALOS_DIR}}" && talhelper genconfig

# Apply Talos config to a specific node (usage: just talos apply-node IP=192.168.1.160)
apply-node IP MODE="auto":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{TALOS_DIR}}"
    talhelper gencommand apply --node "{{IP}}" --extra-flags "--mode={{MODE}}" | bash

# Upgrade Talos on a single node (usage: just talos upgrade-node IP=192.168.1.160)
upgrade-node IP:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{TALOS_DIR}}"
    TALOS_IMAGE=$(yq '.nodes[] | select(.ipAddress == "{{IP}}") | .talosImageURL' "{{TALOS_DIR}}/talconfig.yaml")
    TALOS_VERSION=$(yq '.talosVersion' "{{TALOS_DIR}}/talenv.yaml")
    talhelper gencommand upgrade --node "{{IP}}" \
        --extra-flags "--image='${TALOS_IMAGE}:${TALOS_VERSION}' --timeout=10m" | bash

# Upgrade Kubernetes to the version defined in talos/talenv.yaml
upgrade-k8s:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{TALOS_DIR}}"
    K8S_VERSION=$(yq '.kubernetesVersion' "{{TALOS_DIR}}/talenv.yaml")
    talhelper gencommand upgrade-k8s --extra-flags "--to '${K8S_VERSION}'" | bash

# Reset all nodes back to maintenance mode (destroys cluster state)
[confirm("This will destroy your cluster and reset nodes to maintenance mode... continue?")]
reset:
    cd "{{TALOS_DIR}}" && talhelper gencommand reset \
        --extra-flags="--reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false --wait=false" \
        | bash
