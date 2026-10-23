set shell := ["bash", "-euo", "pipefail", "-c"]
set minimum-version := "1.55.1"

# Export env vars so all module recipes can access them as $VAR
export KUBECONFIG := justfile_directory() + "/kubeconfig"
export SOPS_AGE_KEY_FILE := justfile_directory() + "/age.key"
export SOPS_CONFIG := justfile_directory() + "/.sops.yaml"
export TALOSCONFIG := justfile_directory() + "/talos/talosconfig"

mod bootstrap "bootstrap"
mod talos "talos"
mod template "templates"
mod ops "ops"

# List all available recipes
default:
    @just --list

# Render and validate all configuration files (overwrites kubernetes/)
[confirm("Any conflicting files in the kubernetes directory will be overwritten... continue?")]
configure:
    just template configure

# Shortcut: initialise new cluster configuration from cluster.sample.toml
init:
    just template init

# Force Flux to pull in changes from your Git repository
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source
