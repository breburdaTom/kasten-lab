#!/usr/bin/env bash
# ==============================================================================
# Script: destroy-app.sh
# Description: Destroys the PostgreSQL application to simulate data loss
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
WAIT_TIMEOUT="${DESTROY_TIMEOUT:-120}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

wait_for_condition() {
    local condition="$1" timeout="${2:-120}" interval="${3:-5}" description="${4:-condition}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then return 0; fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}

show_current_state() {
    log_info "Current state before destruction:"
    log_info "StatefulSets:"; kubectl get statefulset -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
    log_info "Pods:"; kubectl get pods -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
    log_info "PVCs:"; kubectl get pvc -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
}

delete_statefulset() {
    log_info "Deleting StatefulSet pg-database..."
    if kubectl get statefulset pg-database -n "${APP_NAMESPACE}" &>/dev/null; then
        kubectl delete statefulset pg-database -n "${APP_NAMESPACE}" --wait=true --timeout="${WAIT_TIMEOUT}s"
        log_info "StatefulSet deleted"
    else
        log_warn "StatefulSet pg-database not found, skipping"
    fi
}

delete_pvcs() {
    log_info "Deleting PersistentVolumeClaims..."
    local pvcs
    pvcs=$(kubectl get pvc -n "${APP_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "${pvcs}" ]]; then
        for pvc in ${pvcs}; do
            log_info "Deleting PVC: ${pvc}"
            kubectl delete pvc "${pvc}" -n "${APP_NAMESPACE}" --wait=true --timeout="${WAIT_TIMEOUT}s"
        done
        log_info "All PVCs deleted"
    else
        log_warn "No PVCs found, skipping"
    fi
}

delete_pods() {
    log_info "Deleting any remaining pods..."
    local pods
    pods=$(kubectl get pods -n "${APP_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    for pod in ${pods}; do
        log_info "Deleting pod: ${pod}"
        kubectl delete pod "${pod}" -n "${APP_NAMESPACE}" --force --grace-period=0 2>/dev/null || true
    done
}

verify_destruction() {
    log_info "Verifying application destruction..."
    
    wait_for_condition "! kubectl get statefulset pg-database -n ${APP_NAMESPACE} &>/dev/null" 60 5 "StatefulSet deletion"
    wait_for_condition "[[ \$(kubectl get pods -n ${APP_NAMESPACE} --no-headers 2>/dev/null | wc -l) -eq 0 ]]" 60 5 "all pods deletion"
    wait_for_condition "[[ \$(kubectl get pvc -n ${APP_NAMESPACE} --no-headers 2>/dev/null | wc -l) -eq 0 ]]" 60 5 "all PVCs deletion"
    
    log_info "Application destruction verified"
    log_info "Final state after destruction:"
    log_info "StatefulSets:"; kubectl get statefulset -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
    log_info "Pods:"; kubectl get pods -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
    log_info "PVCs:"; kubectl get pvc -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
}

verify_snapshot_data_preserved() {
    log_info "Verifying snapshot data is preserved for restore..."
    
    # Check VolumeSnapshotContents (cluster-scoped, actual snapshot data)
    local vsc_count
    vsc_count=$(kubectl get volumesnapshotcontents --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "${vsc_count}" -eq 0 ]]; then
        log_error "WARNING: No VolumeSnapshotContents found!"
        log_error "This means snapshot data has been deleted along with the PVCs."
        log_error "This happens when VolumeSnapshotClass deletionPolicy is 'Delete'."
        log_error ""
        log_error "To fix this for future backups:"
        log_error "  1. Patch VolumeSnapshotClass: kubectl patch volumesnapshotclass csi-hostpath-snapclass --type='json' -p='[{\"op\": \"replace\", \"path\": \"/deletionPolicy\", \"value\":\"Retain\"}]'"
        log_error "  2. Re-run the backup"
        log_error ""
        log_info "Current VolumeSnapshotClass policies:"
        kubectl get volumesnapshotclass -o custom-columns='NAME:.metadata.name,POLICY:.deletionPolicy' 2>/dev/null || true
        return 1
    else
        log_info "VolumeSnapshotContents preserved: ${vsc_count}"
        log_info "Snapshot data is available for restore."
    fi
    
    # Check RestorePoints still exist
    local rp_count
    rp_count=$(kubectl get restorepoints -n "${APP_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")
    log_info "RestorePoints in ${APP_NAMESPACE}: ${rp_count}"
    
    if [[ "${rp_count}" -eq 0 ]]; then
        log_warn "No RestorePoints found in ${APP_NAMESPACE}"
        log_info "Checking all namespaces for RestorePoints..."
        kubectl get restorepoints --all-namespaces 2>/dev/null || echo "  None found"
    fi
    
    return 0
}

main() {
    log_info "Starting application destruction..."
    log_warn "⚠️  This will DELETE all application data! ⚠️"
    
    # Check VolumeSnapshotClass deletion policy before destruction
    log_info "Checking VolumeSnapshotClass deletion policies..."
    kubectl get volumesnapshotclass -o custom-columns='NAME:.metadata.name,POLICY:.deletionPolicy' 2>/dev/null || true
    
    local delete_policy
    delete_policy=$(kubectl get volumesnapshotclass csi-hostpath-snapclass -o jsonpath='{.deletionPolicy}' 2>/dev/null || echo "unknown")
    if [[ "${delete_policy}" == "Delete" ]]; then
        log_warn "VolumeSnapshotClass has deletionPolicy=Delete!"
        log_warn "Deleting PVCs will also delete snapshot data, making restore impossible!"
        log_warn "Consider patching to Retain before proceeding."
    fi
    
    show_current_state
    delete_statefulset
    delete_pods
    delete_pvcs
    verify_destruction
    
    # Verify snapshot data is still available
    verify_snapshot_data_preserved
    
    log_info "Application destruction completed successfully!"
    log_info "The application and all its data have been deleted."
    log_info "RestorePoints in Kasten K10 are still available for recovery."
}

main "$@"
