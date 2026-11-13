set shell := ["bash", "-euo", "pipefail", "-c"]
set minimum-version := "1.55.1"

# Export env vars so all module recipes can access them as $VAR
export KUBECONFIG        := justfile_directory() + "/kubeconfig"
export SOPS_AGE_KEY_FILE := justfile_directory() + "/age.key"
export SOPS_CONFIG       := justfile_directory() + "/.sops.yaml"
export TALOSCONFIG       := justfile_directory() + "/talos/talosconfig"

mod bootstrap "bootstrap"
mod talos "talos"
mod ops "ops"

# List all available recipes
default:
    @just --list

# Shared structured log helper (used by template::doctor and ops::*)
[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{lvl}}" "{{msg}}" {{args}}

# Force Argo CD to re-read Git and re-render every Application
[doc("Hard-refresh all Argo CD Applications from git")]
reconcile:
    kubectl -n argo-system annotate applications --all argocd.argoproj.io/refresh=hard --overwrite

