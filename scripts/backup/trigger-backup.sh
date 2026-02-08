#!/usr/bin/env bash
# ==============================================================================
# Script: trigger-backup.sh
# Description: Triggers a manual backup using Kasten K10 RunAction
# ==============================================================================

set -euo pipefail

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
    log_info "Creating RunAction: ${run_action_name}"
    
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
    echo "${run_action_name}"
}

wait_for_backup() {
    local run_action_name="$1" elapsed=0 interval=15
    log_info "Waiting for backup (timeout: ${BACKUP_TIMEOUT}s)..."
    
    while [[ $elapsed -lt $BACKUP_TIMEOUT ]]; do
        # Get RunAction state and details
        local run_state run_error
        run_state=$(kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        run_error=$(kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.error}' 2>/dev/null || echo "")
        
        # Get BackupAction
        local ba_name ba_state
        ba_name=$(kubectl get backupactions -n "${K10_NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$ba_name" ]]; then
            ba_state=$(kubectl get backupaction "$ba_name" -n "${K10_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
            log_info "RunAction: ${run_state:-Creating} | BackupAction: ${ba_name} (${ba_state}) | ${elapsed}s"
            
            [[ "$ba_state" == "Complete" ]] && { log_info "Backup completed!"; return 0; }
            [[ "$ba_state" == "Failed" ]] && { log_error "Backup failed!"; kubectl get backupaction "$ba_name" -n "${K10_NAMESPACE}" -o yaml; return 1; }
        else
            log_info "RunAction: ${run_state:-Creating} | No BackupAction yet | ${elapsed}s"
            # Show RunAction details if stuck
            if [[ $elapsed -ge 60 && -z "$ba_name" ]]; then
                log_warn "RunAction stuck, showing details:"
                kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null | grep -A20 "status:" || true
            fi
        fi
        
        # Check for failures
        if [[ "$run_state" == "Failed" || -n "$run_error" ]]; then
            log_error "RunAction failed: ${run_error}"
            kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml
            return 1
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout! Final state:"
    kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null || true
    return 1
}

verify_restore_point() {
    log_info "Checking RestorePoints..."
    sleep 5
    
    local rp_name
    rp_name=$(kubectl get restorepoints -n "${APP_NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$rp_name" ]]; then
        local rp_state
        rp_state=$(kubectl get restorepoint "$rp_name" -n "${APP_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        log_info "RestorePoint: ${rp_name} (${rp_state})"
    else
        log_warn "No RestorePoints found yet in ${APP_NAMESPACE}"
        kubectl get restorepoints --all-namespaces 2>/dev/null || true
    fi
}

main() {
    log_info "Starting backup..."
    
    # Verify policy exists
    kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null || { log_error "Policy ${POLICY_NAME} not found"; exit 1; }
    
    local run_action_name
    run_action_name=$(trigger_backup)
    wait_for_backup "${run_action_name}"
    verify_restore_point
    log_info "Backup completed successfully!"
}

main "$@"
