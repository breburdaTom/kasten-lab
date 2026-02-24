#!/usr/bin/env bash
# ==============================================================================
# Script: deploy-postgres.sh
# Description: Deploys PostgreSQL StatefulSet for backup/restore testing
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source shared utilities
source "${SCRIPT_DIR}/../lib/common.sh"

APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POSTGRES_DIR="${PROJECT_ROOT}/manifests/app/postgres"
READY_TIMEOUT="${APP_READY_TIMEOUT:-300}"

deploy_postgres() {
    log_info "Deploying PostgreSQL manifests..."

    if [[ ! -d "${POSTGRES_DIR}" ]]; then
        log_error "PostgreSQL manifests directory not found: ${POSTGRES_DIR}"
        exit 1
    fi

    kubectl apply -f "${POSTGRES_DIR}/namespace.yaml"
    kubectl apply -f "${POSTGRES_DIR}/service.yaml"
    kubectl apply -f "${POSTGRES_DIR}/statefulset.yaml"
    log_info "PostgreSQL manifests applied"
}

wait_for_postgres_ready() {
    log_info "Waiting for PostgreSQL to be ready (timeout: ${READY_TIMEOUT}s)..."
    
    wait_for_condition \
        "kubectl get statefulset pg-database -n ${APP_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '1'" \
        "${READY_TIMEOUT}" 10 "PostgreSQL StatefulSet ready"
    
    wait_for_condition \
        "kubectl get pod pg-database-0 -n ${APP_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'" \
        60 5 "PostgreSQL pod running"
    
    log_info "Waiting for PostgreSQL to accept connections..."
    wait_for_condition \
        "kubectl exec -n ${APP_NAMESPACE} pg-database-0 -- pg_isready -U postgres 2>/dev/null | grep -q 'accepting connections'" \
        120 5 "PostgreSQL accepting connections"
    
    log_info "PostgreSQL is ready"
}

verify_deployment() {
    log_info "Verifying PostgreSQL deployment..."
    
    log_info "StatefulSet:"
    kubectl get statefulset -n "${APP_NAMESPACE}"
    
    log_info "Pods:"
    kubectl get pods -n "${APP_NAMESPACE}"
    
    log_info "PersistentVolumeClaims:"
    kubectl get pvc -n "${APP_NAMESPACE}"
    
    log_info "PersistentVolumes:"
    kubectl get pv | grep "${APP_NAMESPACE}" || true
    
    log_info "Testing PostgreSQL connection..."
    kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -c "SELECT version();"
    
    log_info "PostgreSQL deployment verified"
}

main() {
    log_info "Starting PostgreSQL deployment..."
    deploy_postgres
    wait_for_postgres_ready
    verify_deployment
    log_info "PostgreSQL deployment completed successfully!"
}

main "$@"
