#!/usr/bin/env bash
# ==============================================================================
# Script: trigger-backup.sh
# Description: Triggers a manual backup using Kasten K10 RunAction
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-600}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Generate unique run action name
generate_run_action_name() {
    echo "manual-backup-$(date +%Y%m%d%H%M%S)"
}

# Trigger backup
trigger_backup() {
    local run_action_name
    run_action_name=$(generate_run_action_name)
    
    log_info "Triggering backup with RunAction: ${run_action_name}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  name: ${run_action_name}
  namespace: ${K10_NAMESPACE}
spec:
  subject:
    kind: Policy
    name: ${POLICY_NAME}
    namespace: ${K10_NAMESPACE}
EOF
    
    log_info "RunAction created: ${run_action_name}"
    echo "${run_action_name}"
}

# Wait for backup to complete
wait_for_backup() {
    local run_action_name="$1"
    local timeout="${BACKUP_TIMEOUT}"
    local interval=10
    local elapsed=0
    
    log_info "Waiting for backup to complete (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        # Get the BackupAction created by the RunAction
        local backup_action
        backup_action=$(kubectl get backupactions -n "${K10_NAMESPACE}" \
            -l "k10.kasten.io/policyName=${POLICY_NAME}" \
            --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "${backup_action}" ]]; then
            local state
            state=$(kubectl get backupaction "${backup_action}" -n "${K10_NAMESPACE}" \
                -o jsonpath='{.status.state}' 2>/dev/null || echo "")
            
            log_info "BackupAction: ${backup_action}, State: ${state}"
            
            case "${state}" in
                "Complete")
                    log_info "Backup completed successfully!"
                    return 0
                    ;;
                "Failed")
                    local error
                    error=$(kubectl get backupaction "${backup_action}" -n "${K10_NAMESPACE}" \
                        -o jsonpath='{.status.error}' 2>/dev/null || echo "Unknown error")
                    log_error "Backup failed: ${error}"
                    return 1
                    ;;
                *)
                    # Still running
                    ;;
            esac
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for backup... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for backup to complete"
    return 1
}

# Verify restore point was created
verify_restore_point() {
    log_info "Verifying RestorePoint was created..."
    
    # Wait a bit for RestorePoint to be created
    sleep 10
    
    # Get RestorePoints for the application namespace
    local restore_points
    restore_points=$(kubectl get restorepoints -n "${APP_NAMESPACE}" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${restore_points}" ]]; then
        log_error "No RestorePoints found for namespace ${APP_NAMESPACE}"
        return 1
    fi
    
    log_info "RestorePoint created: ${restore_points}"
    
    # Show RestorePoint details
    log_info "RestorePoint details:"
    kubectl get restorepoints -n "${APP_NAMESPACE}"
    
    # Verify RestorePoint status
    local rp_status
    rp_status=$(kubectl get restorepoint "${restore_points}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    
    log_info "RestorePoint status: ${rp_status}"
    
    if [[ "${rp_status}" != "Available" ]]; then
        log_warn "RestorePoint is not yet Available, current state: ${rp_status}"
    fi
    
    return 0
}

# Main execution
main() {
    log_info "Starting backup trigger..."
    
    # Trigger the backup
    local run_action_name
    run_action_name=$(trigger_backup)
    
    # Wait for completion
    wait_for_backup "${run_action_name}"
    
    # Verify restore point
    verify_restore_point
    
    log_info "Backup trigger completed successfully!"
}

main "$@"
