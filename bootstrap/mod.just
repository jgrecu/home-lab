set shell := ["bash", "-euo", "pipefail", "-c"]

REPO_ROOT   := source_directory() + "/.."
TALOS_DIR   := REPO_ROOT + "/talos"
SCRIPTS_DIR := REPO_ROOT + "/scripts"

# Bootstrap the Talos cluster from scratch
bootstrap-talos:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{TALOS_DIR}}"
    if [[ ! -f talsecret.sops.yaml ]]; then
        talhelper gensecret | sops --filename-override talos/talsecret.sops.yaml --encrypt /dev/stdin > talsecret.sops.yaml
    fi
    talhelper genconfig
    talhelper gencommand apply --extra-flags="--insecure" | bash
    until talhelper gencommand bootstrap | bash; do sleep 10; done
    until talhelper gencommand kubeconfig --extra-flags="{{REPO_ROOT}} --force" | bash; do sleep 10; done

# Bootstrap Flux and Helm apps into a running Talos cluster
bootstrap-apps:
    bash "{{SCRIPTS_DIR}}/bootstrap-apps.sh"
