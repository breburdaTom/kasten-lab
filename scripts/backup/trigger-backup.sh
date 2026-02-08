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
        # Get RunAction status
        local run_state
        run_state=$(kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "Pending")
        
        # Per Kasten docs: BackupActions subordinate to a RunAction are labeled with k10.kasten.io/runActionName
        # and are created in the application namespace
        local ba_info ba_name ba_state ba_progress
        ba_info=$(kubectl get backupactions.actions.kio.kasten.io \
            -l "k10.kasten.io/runActionName=${run_action_name}" \
            --all-namespaces \
            -o jsonpath='{.items[0].metadata.namespace},{.items[0].metadata.name},{.items[0].status.state},{.items[0].status.progress}' 2>/dev/null || echo "")
        
        if [[ -n "$ba_info" && "$ba_info" != ",,," ]]; then
            IFS=',' read -r ba_namespace ba_name ba_state ba_progress <<< "$ba_info"
            log_info "RunAction: ${run_state} | BackupAction: ${ba_name} (${ba_state}, ${ba_progress:-0}%) | ${elapsed}s"
            
            if [[ "$ba_state" == "Complete" ]]; then
                log_info "Backup completed successfully!"
                return 0
            fi
            if [[ "$ba_state" == "Failed" ]]; then
                log_error "Backup failed!"
                kubectl get backupaction "$ba_name" -n "$ba_namespace" -o yaml
                return 1
            fi
        else
            log_info "RunAction: ${run_state} | No BackupAction yet | ${elapsed}s"
        fi
        
        # Check if RunAction completed or failed
        if [[ "$run_state" == "Complete" ]]; then
            if [[ -n "$ba_name" && "$ba_state" == "Complete" ]]; then
                return 0
            elif [[ -z "$ba_name" || "$ba_info" == ",,," ]]; then
                log_warn "RunAction completed but no BackupAction was created."
                log_warn "This usually means the policy selector didn't match any applications."
                kubectl get applications.apps.kio.kasten.io --all-namespaces 2>/dev/null || true
                return 1
            fi
        fi
        
        if [[ "$run_state" == "Failed" ]]; then
            log_error "RunAction failed!"
            kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null || true
            return 1
        fi
        
        # Show debug info every 60 seconds if no BackupAction found
        if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 && ( -z "$ba_info" || "$ba_info" == ",,," ) ]]; then
            log_warn "=== Debug: RunAction status ==="
            kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null || true
            log_warn "=== Debug: Policy status ==="
            kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null | grep -A10 "status:" || true
            log_warn "=== Debug: K10 apps in ${APP_NAMESPACE} ==="
            kubectl get applications.apps.kio.kasten.io -n "${APP_NAMESPACE}" 2>/dev/null || echo "No K10 applications found"
            log_warn "=== Debug: All BackupActions with runActionName label ==="
            kubectl get backupactions.actions.kio.kasten.io -l "k10.kasten.io/runActionName=${run_action_name}" --all-namespaces 2>/dev/null || echo "No BackupActions found"
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout! Final state:"
    kubectl get runaction "${run_action_name}" -n "${K10_NAMESPACE}" -o yaml 2>/dev/null || true
    kubectl get backupactions.actions.kio.kasten.io -l "k10.kasten.io/runActionName=${run_action_name}" --all-namespaces 2>/dev/null || true
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
    
    # Verify policy exists and show its status
    log_info "Checking policy ${POLICY_NAME}..."
    if ! kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_error "Policy ${POLICY_NAME} not found"
        exit 1
    fi
    kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o wide
    
    # Check if K10 discovered the application
    log_info "Checking K10 application discovery for ${APP_NAMESPACE}..."
    kubectl get applications.apps.kio.kasten.io -n "${APP_NAMESPACE}" 2>/dev/null || log_warn "No K10 applications discovered in ${APP_NAMESPACE}"
    
    local run_action_name
    run_action_name=$(trigger_backup)
    wait_for_backup "${run_action_name}"
    verify_restore_point
    log_info "Backup completed successfully!"
}

main "$@"
