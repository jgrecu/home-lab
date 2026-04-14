#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Check prerequisites
function check_prerequisites() {
    log debug "Checking prerequisites"
    check_cli "kubectl" "jq" "curl"

    # Check if garage pod is running
    if ! kubectl get pod -n storage garage-0 &>/dev/null; then
        log error "Garage pod not found" "pod=garage-0" "namespace=storage"
    fi

    # Check if garage is ready
    if ! kubectl get pod -n storage garage-0 -o jsonpath='{.status.phase}' | grep -q "Running"; then
        log error "Garage pod is not running" "pod=garage-0"
    fi

    log info "Prerequisites check passed"
}

# Get garage admin token from secret
function get_admin_token() {
    log debug "Retrieving garage admin token"

    local garage_toml
    garage_toml=$(kubectl get secret -n storage garage-config -o jsonpath='{.data.garage\.toml}' | base64 -d 2>/dev/null)

    if [[ -z "${garage_toml}" ]]; then
        log error "Failed to retrieve garage config" "secret=garage-config"
    fi

    # Extract admin_token from TOML (format: admin_token = "token_value")
    local token
    token=$(echo "${garage_toml}" | grep 'admin_token' | sed 's/.*admin_token = "\(.*\)".*/\1/' | tr -d '\n\r')

    if [[ -z "${token}" ]]; then
        log error "Failed to extract admin token from garage.toml"
    fi

    echo "${token}"
}

# Call garage admin API
function garage_api() {
    local method="${1}"
    local endpoint="${2}"
    local data="${3:-}"
    local token="${GARAGE_ADMIN_TOKEN}"

    local url="http://localhost:3903${endpoint}"
    local response
    local http_code

    log debug "Calling garage API" "method=${method}" "endpoint=${endpoint}"

    # Use kubectl port-forward to access garage admin API
    kubectl port-forward -n storage svc/garage-admin 3903:3903 >/dev/null 2>&1 &
    local port_forward_pid=$!

    # Wait for port-forward to be ready
    sleep 3

    # Make the API call
    if [[ -n "${data}" ]]; then
        http_code=$(curl -s -o /tmp/garage_response.json -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${url}" 2>&1)
    else
        http_code=$(curl -s -o /tmp/garage_response.json -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            "${url}" 2>&1)
    fi

    response=$(cat /tmp/garage_response.json 2>/dev/null || echo "")
    rm -f /tmp/garage_response.json

    # Kill port-forward
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true

    if [[ "${http_code}" != "200" ]] && [[ "${http_code}" != "204" ]]; then
        log error "Garage API call failed" "http_code=${http_code}" "response=${response:0:200}"
    fi

    echo "${response}"
}

# Get cluster layout
function get_layout() {
    garage_api "GET" "/v1/layout"
}

# Get node ID
function get_node_id() {
    garage_api "GET" "/v1/status" | jq -r '.nodes[0].id // empty'
}

# Check if cluster is initialized
function is_initialized() {
    local layout
    layout=$(get_layout)

    if echo "${layout}" | jq -e '.version > 0' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Initialize garage cluster layout
function init_layout() {
    log info "Initializing garage cluster layout"

    local node_id
    node_id=$(get_node_id)

    if [[ -z "${node_id}" ]]; then
        log error "Failed to get garage node ID"
    fi

    log debug "Got garage node ID" "node_id=${node_id}"

    # Assign layout to node - payload is an array of role assignments
    local layout_update
    layout_update=$(jq -n \
        --arg node_id "${node_id}" \
        '[{
            "id": $node_id,
            "zone": "dc1",
            "capacity": 107374182400,
            "tags": []
        }]')

    garage_api "POST" "/v1/layout" "${layout_update}" >/dev/null
    log info "Layout assigned to node" "node_id=${node_id}" "zone=dc1" "capacity=100GB"

    # Apply layout
    local current_version
    current_version=$(get_layout | jq -r '.version')

    local apply_payload
    apply_payload=$(jq -n \
        --argjson version "${current_version}" \
        '{
            "version": ($version + 1)
        }')

    garage_api "POST" "/v1/layout/apply" "${apply_payload}" >/dev/null
    log info "Layout applied successfully" "version=$((current_version + 1))"
}

# List buckets
function list_buckets() {
    garage_api "GET" "/v1/bucket" | jq -r '.[].name // empty'
}

# Create bucket
function create_bucket() {
    local bucket_name="${1}"

    log info "Creating bucket" "bucket=${bucket_name}"

    local payload
    payload=$(jq -n \
        --arg name "${bucket_name}" \
        '{
            "globalAlias": $name
        }')

    local bucket_info
    local http_code

    # Try to create bucket
    kubectl port-forward -n storage svc/garage-admin 3903:3903 >/dev/null 2>&1 &
    local port_forward_pid=$!
    sleep 3

    http_code=$(curl -s -o /tmp/garage_response.json -w "%{http_code}" \
        -X "POST" \
        -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://localhost:3903/v1/bucket" 2>&1)

    bucket_info=$(cat /tmp/garage_response.json 2>/dev/null || echo "")
    rm -f /tmp/garage_response.json

    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true

    if [[ "${http_code}" == "200" ]]; then
        local bucket_id
        bucket_id=$(echo "${bucket_info}" | jq -r '.id')
        log info "Bucket created" "bucket=${bucket_name}" "id=${bucket_id}"
        echo "${bucket_id}"
    elif [[ "${http_code}" == "409" ]]; then
        log info "Bucket already exists" "bucket=${bucket_name}"
        # Get existing bucket ID
        local buckets
        buckets=$(garage_api "GET" "/v1/bucket")
        local bucket_id
        bucket_id=$(echo "${buckets}" | jq -r ".[] | select(.globalAliases[] == \"${bucket_name}\") | .id // empty" | head -1)
        echo "${bucket_id}"
    else
        log error "Failed to create bucket" "http_code=${http_code}" "response=${bucket_info}"
    fi
}

# List keys
function list_keys() {
    garage_api "GET" "/v1/key" | jq -r '.[].name // empty'
}

# Get key info
function get_key_info() {
    local key_name="${1}"

    # List all keys and find by name
    local keys
    keys=$(garage_api "GET" "/v1/key")

    local key_id
    key_id=$(echo "${keys}" | jq -r ".[] | select(.name == \"${key_name}\") | .id // empty" | head -1)

    if [[ -z "${key_id}" ]]; then
        return 1
    fi

    # Get full key info including accessKeyId and secretAccessKey
    garage_api "GET" "/v1/key?id=${key_id}"
}

# Create key
function create_key() {
    local key_name="${1}"

    log info "Creating S3 key" "key=${key_name}"

    local payload
    payload=$(jq -n \
        --arg name "${key_name}" \
        '{
            "name": $name
        }')

    local key_info
    key_info=$(garage_api "POST" "/v1/key" "${payload}")

    # Save to temp file for debugging
    echo "${key_info}" > /tmp/garage_key_info.txt
    log debug "Key creation response saved to /tmp/garage_key_info.txt"

    log info "S3 key created" "key=${key_name}"

    echo "${key_info}"
}

# Grant bucket permissions to key
function grant_permissions() {
    local bucket_name="${1}"
    local key_name="${2}"

    log info "Granting permissions" "bucket=${bucket_name}" "key=${key_name}"

    # Get bucket ID
    local buckets
    buckets=$(garage_api "GET" "/v1/bucket")
    local bucket_id
    bucket_id=$(echo "${buckets}" | jq -r ".[] | select(.globalAliases[] == \"${bucket_name}\") | .id // empty")

    if [[ -z "${bucket_id}" ]]; then
        log error "Bucket not found" "bucket=${bucket_name}"
    fi

    # Get key ID
    local keys
    keys=$(garage_api "GET" "/v1/key")
    local key_id
    key_id=$(echo "${keys}" | jq -r ".[] | select(.name == \"${key_name}\") | .id // empty")

    if [[ -z "${key_id}" ]]; then
        log error "Key not found" "key=${key_name}"
    fi

    # Grant permissions
    local payload
    payload=$(jq -n \
        --arg key_id "${key_id}" \
        '{
            "permissions": {
                "read": true,
                "write": true,
                "owner": true
            },
            "bucketId": null,
            "accessKeyId": $key_id
        }')

    garage_api "POST" "/v1/bucket/${bucket_id}/allow" "${payload}" >/dev/null

    log info "Permissions granted" "bucket=${bucket_name}" "key=${key_name}" "permissions=read,write,owner"
}

# Update cluster.yaml with S3 credentials
function update_cluster_config() {
    local access_key_id="${1}"
    local secret_access_key="${2}"

    log info "Updating cluster.yaml with S3 credentials"

    local cluster_yaml="${ROOT_DIR}/cluster.yaml"

    if [[ ! -f "${cluster_yaml}" ]]; then
        log error "cluster.yaml not found" "path=${cluster_yaml}"
    fi

    # Create a backup
    cp "${cluster_yaml}" "${cluster_yaml}.bak"
    log debug "Created backup" "file=${cluster_yaml}.bak"

    # Update credentials using sed
    sed -i.tmp "s|^garage_s3_access_key_id:.*|garage_s3_access_key_id: \"${access_key_id}\"|" "${cluster_yaml}"
    sed -i.tmp "s|^garage_s3_secret_access_key:.*|garage_s3_secret_access_key: \"${secret_access_key}\"|" "${cluster_yaml}"
    rm -f "${cluster_yaml}.tmp"

    log info "cluster.yaml updated successfully"
    log warn "You need to run 'task configure' to regenerate templates with new credentials"
}

# Main bootstrap function
function main() {
    log info "Starting Garage S3 bootstrap"

    check_prerequisites

    # Get admin token
    GARAGE_ADMIN_TOKEN=$(get_admin_token)
    export GARAGE_ADMIN_TOKEN

    # Check if already initialized
    if is_initialized; then
        log info "Garage cluster already initialized, checking configuration"
    else
        log info "Garage cluster not initialized, starting bootstrap"
        init_layout

        # Wait for layout to be applied
        log info "Waiting for layout to stabilize..."
        sleep 5
    fi

    # Create required buckets
    local required_buckets=("longhorn-backups" "cnpg-backups")
    local existing_buckets
    existing_buckets=$(list_buckets)

    for bucket in "${required_buckets[@]}"; do
        if echo "${existing_buckets}" | grep -q "^${bucket}$"; then
            log info "Bucket already exists" "bucket=${bucket}"
        else
            create_bucket "${bucket}" >/dev/null  # Redirect bucket ID output
        fi
    done

    # Create or get S3 key
    local key_name="home-lab"
    local key_info
    local access_key_id
    local secret_access_key

    if key_info=$(get_key_info "${key_name}" 2>/dev/null); then
        log info "S3 key already exists" "key=${key_name}"
        access_key_id=$(echo "${key_info}" | jq -r '.accessKeyId')

        # Secret is not returned for existing keys - check if already in cluster.yaml
        if grep -q "^garage_s3_access_key_id: \"${access_key_id}\"" "${ROOT_DIR}/cluster.yaml" 2>/dev/null; then
            log info "S3 credentials already configured in cluster.yaml"
            secret_access_key=$(grep "^garage_s3_secret_access_key:" "${ROOT_DIR}/cluster.yaml" | sed 's/.*: "\(.*\)".*/\1/')

            if [[ -z "${secret_access_key}" ]] || [[ "${secret_access_key}" == "" ]]; then
                log warn "S3 key exists but secret is not in cluster.yaml - you may need to recreate the key"
                log info "To recreate: delete the key in Garage admin UI and run this script again"
                exit 0
            fi
        else
            log warn "S3 key exists but credentials don't match cluster.yaml"
            log info "Using existing key, but secret access key is unknown - you may need to update cluster.yaml manually"
            log info "Or delete the key and run this script again to create a new one"
            exit 0
        fi
    else
        log info "Creating new S3 key" "key=${key_name}"
        key_info=$(create_key "${key_name}")
        log debug "Raw key info received" "length=${#key_info}"

        # Parse credentials
        access_key_id=$(echo "${key_info}" | jq -r '.accessKeyId' 2>&1)
        if [[ $? -ne 0 ]]; then
            log error "Failed to parse accessKeyId from response" "jq_output=${access_key_id}" "raw_response=${key_info:0:200}"
        fi

        secret_access_key=$(echo "${key_info}" | jq -r '.secretAccessKey' 2>&1)
        if [[ $? -ne 0 ]]; then
            log error "Failed to parse secretAccessKey from response" "jq_output=${secret_access_key}"
        fi

        log info "S3 key created" "access_key_id=${access_key_id}"
    fi

    # Grant permissions to all buckets
    for bucket in "${required_buckets[@]}"; do
        grant_permissions "${bucket}" "${key_name}"
    done

    # Update cluster.yaml
    update_cluster_config "${access_key_id}" "${secret_access_key}"

    log info "Garage S3 bootstrap completed successfully"
    log info "Next steps:"
    log info "  1. Run: task configure"
    log info "  2. Commit changes: git add cluster.yaml kubernetes/"
    log info "  3. Push: git push"
}

# Run main function
main "$@"
