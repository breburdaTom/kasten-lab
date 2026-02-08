#!/usr/bin/env bash
# ==============================================================================
# Script: trigger-backup.sh
# Description: Triggers a manual backup using Kasten K10 RunAction
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-600}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

trigger_backup() {
    local run_action_name="manual-backup-$(date +%Y%m%d%H%M%S)"
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

wait_for_backup() {
    local run_action_name="$1" elapsed=0 interval=10
    log_info "Waiting for backup to complete (timeout: ${BACKUP_TIMEOUT}s)..."
    
    while [[ $elapsed -lt $BACKUP_TIMEOUT ]]; do
        local backup_action state
        backup_action=$(kubectl get backupactions -n "${K10_NAMESPACE}" \
            -l "k10.kasten.io/policyName=${POLICY_NAME}" \
            --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "${backup_action}" ]]; then
            state=$(kubectl get backupaction "${backup_action}" -n "${K10_NAMESPACE}" \
                -o jsonpath='{.status.state}' 2>/dev/null || echo "")
            log_info "BackupAction: ${backup_action}, State: ${state}"
            
            case "${state}" in
                "Complete") log_info "Backup completed successfully!"; return 0 ;;
                "Failed")
                    log_error "Backup failed: $(kubectl get backupaction "${backup_action}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.error}' 2>/dev/null)"
                    return 1 ;;
            esac
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for backup... (${elapsed}s/${BACKUP_TIMEOUT}s)"
    done
    
    log_error "Timeout waiting for backup to complete"
    return 1
}

verify_restore_point() {
    log_info "Verifying RestorePoint was created..."
    sleep 10
    
    local restore_point
    restore_point=$(kubectl get restorepoints -n "${APP_NAMESPACE}" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${restore_point}" ]]; then
        log_error "No RestorePoints found for namespace ${APP_NAMESPACE}"
        return 1
    fi
    
    log_info "RestorePoint created: ${restore_point}"
    kubectl get restorepoints -n "${APP_NAMESPACE}"
    
    local rp_status
    rp_status=$(kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    log_info "RestorePoint status: ${rp_status}"
    
    [[ "${rp_status}" != "Available" ]] && log_warn "RestorePoint not yet Available, current state: ${rp_status}"
    return 0
}

main() {
    log_info "Starting backup trigger..."
    local run_action_name
    run_action_name=$(trigger_backup)
    wait_for_backup "${run_action_name}"
    verify_restore_point
    log_info "Backup trigger completed successfully!"
}

main "$@"
