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

# Force Flux to pull in changes from your Git repository
[doc("Force Flux to reconcile from git")]
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# === template ===

mod template "templates"

# Pre-flight check: verify all required files exist and cluster.toml is valid
[doc("Pre-flight check — verify required files and validate cluster.toml")]
doctor:
    just template doctor

# Render and validate all configuration files (overwrites kubernetes/)
[confirm("Any conflicting files in the kubernetes directory will be overwritten... continue?")]
[doc("Render templates, encrypt secrets, validate manifests")]
configure:
    just template configure

# Initialise new cluster configuration from cluster.sample.toml
[doc("Create cluster.toml, age key, deploy key, and push token")]
init:
    just template init

# Regenerate cluster.schema.json from the Pydantic validator
[doc("Regenerate cluster.schema.json (run after changing validate.py)")]
schema:
    just template schema
