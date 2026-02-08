#!/usr/bin/env bash
# ==============================================================================
# Script: deploy-postgres.sh
# Description: Deploys PostgreSQL StatefulSet for backup/restore testing
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POSTGRES_MANIFEST="${PROJECT_ROOT}/manifests/postgres.yaml"
READY_TIMEOUT="${APP_READY_TIMEOUT:-300}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Wait for condition with timeout
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-300}"
    local interval="${3:-5}"
    local description="${4:-condition}"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}

# Create namespace
create_namespace() {
    log_info "Creating namespace '${APP_NAMESPACE}'..."
    
    kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Add labels for Kasten to discover
    kubectl label namespace "${APP_NAMESPACE}" \
        app=postgres \
        environment=demo \
        --overwrite
    
    log_info "Namespace created and labeled"
}

# Deploy PostgreSQL
deploy_postgres() {
    log_info "Deploying PostgreSQL StatefulSet..."
    
    if [[ -f "${POSTGRES_MANIFEST}" ]]; then
        kubectl apply -f "${POSTGRES_MANIFEST}"
    else
        log_error "PostgreSQL manifest not found: ${POSTGRES_MANIFEST}"
        exit 1
    fi
    
    log_info "PostgreSQL StatefulSet deployed"
}

# Wait for PostgreSQL to be ready
wait_for_postgres_ready() {
    log_info "Waiting for PostgreSQL to be ready (timeout: ${READY_TIMEOUT}s)..."
    
    # Wait for StatefulSet to be ready
    wait_for_condition \
        "kubectl get statefulset pg-database -n ${APP_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '1'" \
        "${READY_TIMEOUT}" \
        10 \
        "PostgreSQL StatefulSet ready"
    
    # Wait for pod to be running
    wait_for_condition \
        "kubectl get pod pg-database-0 -n ${APP_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'" \
        60 \
        5 \
        "PostgreSQL pod running"
    
    # Wait for PostgreSQL to accept connections
    log_info "Waiting for PostgreSQL to accept connections..."
    wait_for_condition \
        "kubectl exec -n ${APP_NAMESPACE} pg-database-0 -- pg_isready -U postgres 2>/dev/null | grep -q 'accepting connections'" \
        120 \
        5 \
        "PostgreSQL accepting connections"
    
    log_info "PostgreSQL is ready"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying PostgreSQL deployment..."
    
    # Show StatefulSet
    log_info "StatefulSet:"
    kubectl get statefulset -n "${APP_NAMESPACE}"
    
    # Show Pods
    log_info "Pods:"
    kubectl get pods -n "${APP_NAMESPACE}"
    
    # Show PVCs
    log_info "PersistentVolumeClaims:"
    kubectl get pvc -n "${APP_NAMESPACE}"
    
    # Show PVs
    log_info "PersistentVolumes:"
    kubectl get pv | grep "${APP_NAMESPACE}" || true
    
    # Test PostgreSQL connection
    log_info "Testing PostgreSQL connection..."
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -c "SELECT version();"
    
    log_info "PostgreSQL deployment verified"
}

# Main execution
main() {
    log_info "Starting PostgreSQL deployment..."
    
    create_namespace
    deploy_postgres
    wait_for_postgres_ready
    verify_deployment
    
    log_info "PostgreSQL deployment completed successfully!"
}

main "$@"
