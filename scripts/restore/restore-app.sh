#!/usr/bin/env bash
# ==============================================================================
# Script: restore-app.sh
# Description: Restores the PostgreSQL application from a Kasten K10 RestorePoint
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-300}"

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
    local interval="${3:-10}"
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

# Get the latest RestorePoint
get_restore_point() {
    local restore_point_name="${1:-}"
    
    if [[ -n "${restore_point_name}" ]]; then
        # Use provided restore point name
        if kubectl get restorepoint "${restore_point_name}" -n "${APP_NAMESPACE}" &>/dev/null; then
            echo "${restore_point_name}"
            return 0
        else
            log_error "RestorePoint '${restore_point_name}' not found"
            return 1
        fi
    fi
    
    # Get the latest RestorePoint
    local latest_rp
    latest_rp=$(kubectl get restorepoints -n "${APP_NAMESPACE}" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${latest_rp}" ]]; then
        log_error "No RestorePoints found in namespace ${APP_NAMESPACE}"
        return 1
    fi
    
    echo "${latest_rp}"
}

# Create RestoreAction
create_restore_action() {
    local restore_point="$1"
    local restore_action_name="restore-$(date +%Y%m%d%H%M%S)"
    
    log_info "Creating RestoreAction: ${restore_action_name}"
    log_info "Using RestorePoint: ${restore_point}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: ${restore_action_name}
  namespace: ${APP_NAMESPACE}
spec:
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: ${restore_point}
    namespace: ${APP_NAMESPACE}
  targetNamespace: ${APP_NAMESPACE}
EOF
    
    log_info "RestoreAction created"
    echo "${restore_action_name}"
}

# Wait for restore to complete
wait_for_restore() {
    local restore_action_name="$1"
    local timeout="${RESTORE_TIMEOUT}"
    local interval=10
    local elapsed=0
    
    log_info "Waiting for restore to complete (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local state
        state=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
            -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        
        log_info "RestoreAction state: ${state}"
        
        case "${state}" in
            "Complete")
                log_info "Restore completed successfully!"
                return 0
                ;;
            "Failed")
                local error
                error=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                    -o jsonpath='{.status.error}' 2>/dev/null || echo "Unknown error")
                log_error "Restore failed: ${error}"
                return 1
                ;;
            *)
                # Still running
                ;;
        esac
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for restore to complete"
    return 1
}

# Wait for application to be ready
wait_for_app_ready() {
    log_info "Waiting for application to be ready..."
    
    # Wait for StatefulSet to be ready
    wait_for_condition \
        "kubectl get statefulset pg-database -n ${APP_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '1'" \
        180 \
        10 \
        "StatefulSet ready"
    
    # Wait for pod to be running
    wait_for_condition \
        "kubectl get pod pg-database-0 -n ${APP_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'" \
        60 \
        5 \
        "PostgreSQL pod running"
    
    # Wait for PostgreSQL to accept connections
    wait_for_condition \
        "kubectl exec -n ${APP_NAMESPACE} pg-database-0 -- pg_isready -U postgres 2>/dev/null | grep -q 'accepting connections'" \
        120 \
        5 \
        "PostgreSQL accepting connections"
    
    log_info "Application is ready"
}

# Verify restored resources
verify_restore() {
    log_info "Verifying restored resources..."
    
    log_info "StatefulSets:"
    kubectl get statefulset -n "${APP_NAMESPACE}"
    
    log_info "Pods:"
    kubectl get pods -n "${APP_NAMESPACE}"
    
    log_info "PVCs:"
    kubectl get pvc -n "${APP_NAMESPACE}"
    
    # Quick data check
    log_info "Checking restored data..."
    local count
    count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -t -A -c "
        SELECT COUNT(*) FROM test_data;
    " 2>/dev/null || echo "0")
    
    log_info "Records found in restored database: ${count}"
    
    if [[ "${count}" -eq 0 ]]; then
        log_warn "No records found - data may not have been restored correctly"
    fi
}

# Main execution
main() {
    local restore_point_name="${1:-}"
    
    log_info "Starting application restore..."
    
    # Get restore point
    local restore_point
    restore_point=$(get_restore_point "${restore_point_name}")
    log_info "Using RestorePoint: ${restore_point}"
    
    # Show RestorePoint details
    log_info "RestorePoint details:"
    kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" -o yaml
    
    # Create and wait for restore
    local restore_action_name
    restore_action_name=$(create_restore_action "${restore_point}")
    wait_for_restore "${restore_action_name}"
    
    # Wait for application to be ready
    wait_for_app_ready
    
    # Verify restore
    verify_restore
    
    log_info "Application restore completed successfully!"
}

main "$@"
