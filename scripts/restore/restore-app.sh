#!/usr/bin/env bash
# ==============================================================================
# Script: restore-app.sh
# Description: Restores the PostgreSQL application from a Kasten K10 RestorePoint
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-300}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

wait_for_condition() {
    local condition="$1" timeout="${2:-300}" interval="${3:-10}" description="${4:-condition}"
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

diagnose_pending_restore() {
    local restore_action_name="$1"
    
    log_warn "=== DIAGNOSING PENDING RESTOREACTION ==="
    
    # Check if startTime is null (controller hasn't picked it up)
    # RestoreActions are in the app namespace
    local start_time
    start_time=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.status.startTime}' 2>/dev/null || echo "")
    
    if [[ -z "${start_time}" || "${start_time}" == "null" ]]; then
        log_error "RestoreAction has null startTime - Kasten controller is NOT processing it"
        log_info ""
        log_info "Possible causes:"
        log_info "  1. Kasten executor pods are not running"
        log_info "  2. Kasten license is expired or invalid"
        log_info "  3. RestorePointContent data is missing/corrupted"
        log_info "  4. Kasten webhook is not functioning"
        log_info ""
    fi
    
    # Check Kasten pods
    log_info "Kasten K10 pods status:"
    kubectl get pods -n "${K10_NAMESPACE}" 2>/dev/null || echo "  No pods found in ${K10_NAMESPACE}"
    
    # Check for executor specifically
    local executor_running
    executor_running=$(kubectl get pods -n "${K10_NAMESPACE}" --no-headers 2>/dev/null | grep -i executor | grep -c Running || echo "0")
    if [[ "${executor_running}" -eq 0 ]]; then
        log_error "NO RUNNING EXECUTOR PODS FOUND - This is why RestoreAction is stuck!"
        log_info "Check Kasten deployment:"
        kubectl get deployments -n "${K10_NAMESPACE}" 2>/dev/null | head -10 || echo "  No deployments"
    fi
    
    # Check RestorePointContent
    local rp_name
    rp_name=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.spec.subject.name}' 2>/dev/null || echo "")
    if [[ -n "${rp_name}" ]]; then
        local rpc_ref
        rpc_ref=$(kubectl get restorepoint "${rp_name}" -n "${APP_NAMESPACE}" \
            -o jsonpath='{.spec.restorePointContentRef.name}' 2>/dev/null || echo "")
        if [[ -n "${rpc_ref}" ]]; then
            if ! kubectl get restorepointcontent "${rpc_ref}" &>/dev/null; then
                log_error "RestorePointContent '${rpc_ref}' NOT FOUND - backup data may be deleted!"
            fi
        fi
    fi
    
    # Check VolumeSnapshotContents
    local vsc_count
    vsc_count=$(kubectl get volumesnapshotcontents --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "${vsc_count}" -eq 0 ]]; then
        log_error "No VolumeSnapshotContents exist - snapshot data has been deleted!"
        log_info "This typically happens when VolumeSnapshotClass deletionPolicy is 'Delete'"
    else
        log_info "VolumeSnapshotContents found: ${vsc_count}"
    fi
    
    # Check recent events
    log_info "Recent events in ${K10_NAMESPACE}:"
    kubectl get events -n "${K10_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || echo "  No events"
    
    log_info "Recent events in ${APP_NAMESPACE}:"
    kubectl get events -n "${APP_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || echo "  No events"
    
    log_warn "=== END DIAGNOSIS ==="
}

get_restore_point() {
    local restore_point_name="${1:-}"
    
    if [[ -n "${restore_point_name}" ]]; then
        if kubectl get restorepoint "${restore_point_name}" -n "${APP_NAMESPACE}" &>/dev/null; then
            echo "${restore_point_name}"
            return 0
        fi
        log_error "RestorePoint '${restore_point_name}' not found"
        return 1
    fi
    
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

create_restore_action() {
    local restore_point="$1"
    local restore_action_name="restore-$(date +%Y%m%d%H%M%S)"
    
    # Check if there's already a completed RestoreAction for this RestorePoint
    # RestoreActions are in the app namespace (same as targetNamespace)
    log_info "Checking for existing RestoreActions for RestorePoint: ${restore_point}"
    local existing_ra
    existing_ra=$(kubectl get restoreactions -n "${APP_NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name},{.spec.subject.name},{.status.state}{"\n"}{end}' 2>/dev/null | \
        grep ",${restore_point}," | grep ",Complete$" | head -1 | cut -d',' -f1 || echo "")
    
    if [[ -n "${existing_ra}" ]]; then
        log_info "Found existing completed RestoreAction '${existing_ra}' for RestorePoint '${restore_point}'"
        log_info "Skipping creation of new RestoreAction"
        echo "${existing_ra}"
        return 0
    fi
    
    # Check if there's a running RestoreAction for this RestorePoint
    local running_ra
    running_ra=$(kubectl get restoreactions -n "${APP_NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name},{.spec.subject.name},{.status.state}{"\n"}{end}' 2>/dev/null | \
        grep ",${restore_point}," | grep -E ",(Running|Pending)$" | head -1 | cut -d',' -f1 || echo "")
    
    if [[ -n "${running_ra}" ]]; then
        log_info "Found existing in-progress RestoreAction '${running_ra}' for RestorePoint '${restore_point}'"
        log_info "Will wait for existing RestoreAction instead of creating a new one"
        echo "${running_ra}"
        return 0
    fi
    
    log_info "Creating RestoreAction: ${restore_action_name} using RestorePoint: ${restore_point}"
    
    # Get the RestorePointContent reference to verify the backup data exists
    local rpc_name
    rpc_name=$(kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.spec.restorePointContentRef.name}' 2>/dev/null || echo "")
    
    if [[ -z "${rpc_name}" ]]; then
        log_error "RestorePoint '${restore_point}' has no restorePointContentRef - backup may be incomplete"
        return 1
    fi
    log_info "RestorePointContent: ${rpc_name}"
    
    # Verify RestorePointContent exists
    if ! kubectl get restorepointcontent "${rpc_name}" &>/dev/null; then
        log_error "RestorePointContent '${rpc_name}' not found - backup data is missing"
        return 1
    fi
    
    # IMPORTANT: Per Kasten K10 API:
    # - RestoreAction must be created in the SAME namespace as targetNamespace
    # - The subject references the RestorePoint (which is in the app namespace)
    # - For in-place restore (same namespace), we can omit targetNamespace
    cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: ${restore_action_name}
  namespace: ${APP_NAMESPACE}
spec:
  subject:
    kind: RestorePoint
    name: ${restore_point}
    namespace: ${APP_NAMESPACE}
EOF
    
    # Wait a moment for the RestoreAction to be created and picked up by the controller
    sleep 2
    
    # Verify the RestoreAction was created (in app namespace)
    if ! kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" &>/dev/null; then
        log_error "Failed to create RestoreAction"
        return 1
    fi
    
    log_info "RestoreAction created successfully"
    log_info "RestoreAction YAML:"
    kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" -o yaml
    
    echo "${restore_action_name}"
}

wait_for_restore() {
    local restore_action_name="$1" elapsed=0 interval=10
    log_info "Waiting for restore to complete (timeout: ${RESTORE_TIMEOUT}s)..."
    
    while [[ $elapsed -lt $RESTORE_TIMEOUT ]]; do
        # Get RestoreAction details from app namespace
        local state="" progress="" error=""
        
        # RestoreActions are created in app namespace (same as targetNamespace)
        if kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" &>/dev/null; then
            state=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                -o jsonpath='{.status.state}' 2>/dev/null || echo "")
            progress=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                -o jsonpath='{.status.progress}' 2>/dev/null || echo "")
            error=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                -o jsonpath='{.status.error}' 2>/dev/null || echo "")
        fi
        
        # If state is empty, check if RestoreAction exists at all
        if [[ -z "${state}" ]]; then
            local ra_exists
            ra_exists=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" -o name 2>/dev/null || echo "")
            if [[ -z "${ra_exists}" ]]; then
                log_warn "RestoreAction '${restore_action_name}' not found in namespace '${APP_NAMESPACE}'"
                # List all RestoreActions to help debug
                log_info "Available RestoreActions:"
                kubectl get restoreactions --all-namespaces 2>/dev/null || echo "  None found"
            else
                state="Pending"
            fi
        fi
        
        log_info "RestoreAction: ${restore_action_name} | State: ${state:-unknown} | Progress: ${progress:-0}% | Elapsed: ${elapsed}s"
        
        case "${state}" in
            "Complete") 
                log_info "Restore completed successfully!"
                return 0 
                ;;
            "Failed")
                log_error "Restore failed!"
                log_error "Error: ${error}"
                kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" -o yaml 2>/dev/null || true
                return 1 
                ;;
            "Pending")
                # If stuck in Pending for too long, diagnose the issue
                if [[ $elapsed -ge 60 ]]; then
                    log_warn "RestoreAction stuck in Pending state for ${elapsed}s"
                    diagnose_pending_restore "${restore_action_name}"
                fi
                ;;
            "Running")
                # If stuck in Running for too long, diagnose the issue
                if [[ $elapsed -ge 120 ]]; then
                    log_warn "RestoreAction stuck in Running state for ${elapsed}s"
                    log_info "Checking RestoreAction status details..."
                    local ra_status
                    ra_status=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                        -o jsonpath='{.status}' 2>/dev/null || echo "{}")
                    log_info "RestoreAction status: ${ra_status}"
                    
                    # Check if restorePoint.name is empty (indicates controller issue)
                    local rp_in_status
                    rp_in_status=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                        -o jsonpath='{.status.restorePoint.name}' 2>/dev/null || echo "")
                    if [[ -z "${rp_in_status}" ]]; then
                        log_error "RestoreAction status.restorePoint.name is empty!"
                        log_error "This indicates the Kasten controller cannot resolve the RestorePoint reference."
                        log_info "Checking RestorePoint and RestorePointContent..."
                        local rp_name
                        rp_name=$(kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" \
                            -o jsonpath='{.spec.subject.name}' 2>/dev/null || echo "")
                        if [[ -n "${rp_name}" ]]; then
                            log_info "RestorePoint from spec: ${rp_name}"
                            kubectl get restorepoint "${rp_name}" -n "${APP_NAMESPACE}" -o yaml 2>/dev/null || log_error "RestorePoint not found!"
                        fi
                    fi
                    diagnose_pending_restore "${restore_action_name}"
                fi
                ;;
        esac
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for restore to complete after ${RESTORE_TIMEOUT}s"
    log_error "Final RestoreAction state:"
    kubectl get restoreaction "${restore_action_name}" -n "${APP_NAMESPACE}" -o yaml 2>/dev/null || true
    return 1
}

wait_for_app_ready() {
    log_info "Waiting for application to be ready..."
    
    wait_for_condition \
        "kubectl get statefulset pg-database -n ${APP_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '1'" \
        180 10 "StatefulSet ready"
    
    wait_for_condition \
        "kubectl get pod pg-database-0 -n ${APP_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'" \
        60 5 "PostgreSQL pod running"
    
    wait_for_condition \
        "kubectl exec -n ${APP_NAMESPACE} pg-database-0 -- pg_isready -U postgres 2>/dev/null | grep -q 'accepting connections'" \
        120 5 "PostgreSQL accepting connections"
    
    log_info "Application is ready"
}

verify_restore() {
    log_info "Verifying restored resources..."
    
    log_info "StatefulSets:"; kubectl get statefulset -n "${APP_NAMESPACE}"
    log_info "Pods:"; kubectl get pods -n "${APP_NAMESPACE}"
    log_info "PVCs:"; kubectl get pvc -n "${APP_NAMESPACE}"
    
    log_info "Checking restored data..."
    local count
    count=$(kubectl exec -n "${APP_NAMESPACE}" pg-database-0 -- psql -U postgres -d testdb -t -A -c \
        "SELECT COUNT(*) FROM test_data;" 2>/dev/null || echo "0")
    log_info "Records found in restored database: ${count}"
    
    [[ "${count}" -eq 0 ]] && log_warn "No records found - data may not have been restored correctly"
}

verify_restore_point() {
    local restore_point="$1"
    
    log_info "Verifying RestorePoint and its content..."
    
    # Check RestorePoint exists
    if ! kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" &>/dev/null; then
        log_error "RestorePoint '${restore_point}' not found in namespace '${APP_NAMESPACE}'"
        return 1
    fi
    
    # Get RestorePointContent reference
    local rpc_name
    rpc_name=$(kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" \
        -o jsonpath='{.spec.restorePointContentRef.name}' 2>/dev/null || echo "")
    
    if [[ -z "${rpc_name}" ]]; then
        log_error "RestorePoint '${restore_point}' has no restorePointContentRef"
        log_info "RestorePoint YAML:"
        kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" -o yaml
        return 1
    fi
    
    log_info "RestorePointContent reference: ${rpc_name}"
    
    # Check RestorePointContent exists (cluster-scoped resource)
    if ! kubectl get restorepointcontent "${rpc_name}" &>/dev/null; then
        log_error "RestorePointContent '${rpc_name}' not found"
        log_info "Available RestorePointContents:"
        kubectl get restorepointcontents 2>/dev/null | head -10 || echo "  None found"
        return 1
    fi
    
    log_info "RestorePointContent '${rpc_name}' exists"
    
    # Verify RestorePointContent has valid snapshot references
    log_info "Checking RestorePointContent snapshot references..."
    local rpc_yaml
    rpc_yaml=$(kubectl get restorepointcontent "${rpc_name}" -o yaml 2>/dev/null)
    
    # Check if there are volumeSnapshot references in the content
    local vs_refs
    vs_refs=$(echo "${rpc_yaml}" | grep -c "volumeSnapshot" 2>/dev/null || true)
    vs_refs="${vs_refs:-0}"
    # Remove any whitespace/newlines
    vs_refs=$(echo "${vs_refs}" | tr -d '[:space:]')
    if [[ -z "${vs_refs}" || "${vs_refs}" == "0" ]]; then
        log_warn "RestorePointContent has no volumeSnapshot references"
        log_info "RestorePointContent YAML:"
        echo "${rpc_yaml}"
    else
        log_info "RestorePointContent has ${vs_refs} volumeSnapshot reference(s)"
    fi
    
    # Check VolumeSnapshotContents (cluster-scoped, actual snapshot data)
    log_info "Checking VolumeSnapshot data availability..."
    local vsc_count
    vsc_count=$(kubectl get volumesnapshotcontents --no-headers 2>/dev/null | wc -l || echo "0")
    log_info "VolumeSnapshotContents in cluster: ${vsc_count}"
    if [[ "${vsc_count}" -eq 0 ]]; then
        log_error "No VolumeSnapshotContents found - snapshot data has been deleted!"
        log_error "This happens when VolumeSnapshotClass deletionPolicy is 'Delete'"
        log_info "Checking VolumeSnapshotClass policies..."
        kubectl get volumesnapshotclass -o custom-columns='NAME:.metadata.name,POLICY:.deletionPolicy' 2>/dev/null || true
        log_error "Restore will fail. Please re-run the backup with Retain deletion policy."
        return 1
    fi
    
    # Check Kasten controller/executor is running
    log_info "Checking Kasten K10 services status..."
    
    # Check all K10 pods first
    log_info "All Kasten K10 pods:"
    kubectl get pods -n "${K10_NAMESPACE}" 2>/dev/null || echo "  None found"
    
    # Check executor pods (these process RestoreActions)
    local executor_pods
    executor_pods=$(kubectl get pods -n "${K10_NAMESPACE}" -l component=executor --no-headers 2>/dev/null || echo "")
    if [[ -z "${executor_pods}" ]]; then
        # Try alternative label selectors
        executor_pods=$(kubectl get pods -n "${K10_NAMESPACE}" -l app.kubernetes.io/component=executor --no-headers 2>/dev/null || echo "")
    fi
    if [[ -z "${executor_pods}" ]]; then
        # Try finding by name pattern
        executor_pods=$(kubectl get pods -n "${K10_NAMESPACE}" --no-headers 2>/dev/null | grep -i executor || echo "")
    fi
    
    if [[ -z "${executor_pods}" ]]; then
        log_error "No Kasten executor pods found - RestoreActions won't be processed!"
        log_error "This is the root cause of RestoreAction stuck in Pending state"
        log_info "Please verify Kasten K10 is properly installed:"
        log_info "  helm list -n ${K10_NAMESPACE}"
        log_info "  kubectl get deployments -n ${K10_NAMESPACE}"
        return 1
    else
        log_info "Kasten executor pods:"
        echo "${executor_pods}"
        
        # Check if any executor pods are not Running
        local not_running
        not_running=$(echo "${executor_pods}" | grep -v "Running" | grep -v "Completed" | wc -l || echo "0")
        if [[ "${not_running}" -gt 0 ]]; then
            log_error "Executor pods are not in Running state - this causes RestoreAction to stay Pending!"
            log_info "Checking executor pod logs for errors..."
            local executor_pod_name
            executor_pod_name=$(echo "${executor_pods}" | head -1 | awk '{print $1}')
            if [[ -n "${executor_pod_name}" ]]; then
                kubectl logs "${executor_pod_name}" -n "${K10_NAMESPACE}" --tail=50 2>/dev/null || true
            fi
            return 1
        fi
    fi
    
    # Check catalog service (needed for RestorePoint lookups)
    local catalog_pods
    catalog_pods=$(kubectl get pods -n "${K10_NAMESPACE}" -l component=catalog --no-headers 2>/dev/null || echo "")
    if [[ -z "${catalog_pods}" ]]; then
        catalog_pods=$(kubectl get pods -n "${K10_NAMESPACE}" --no-headers 2>/dev/null | grep -i catalog || echo "")
    fi
    if [[ -z "${catalog_pods}" ]]; then
        log_warn "No Kasten catalog pods found"
    else
        log_info "Kasten catalog pods:"
        echo "${catalog_pods}"
    fi
    
    # Check for any pending/failed jobs that might indicate issues
    log_info "Checking for Kasten jobs..."
    kubectl get jobs -n "${K10_NAMESPACE}" --no-headers 2>/dev/null | tail -5 || echo "  No jobs found"
    
    # Check Kasten events for errors
    log_info "Recent Kasten events:"
    kubectl get events -n "${K10_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "  No events"
    
    return 0
}

main() {
    local restore_point_name="${1:-}"
    log_info "Starting application restore..."
    
    local restore_point
    restore_point=$(get_restore_point "${restore_point_name}")
    log_info "Using RestorePoint: ${restore_point}"
    
    log_info "RestorePoint details:"
    kubectl get restorepoint "${restore_point}" -n "${APP_NAMESPACE}" -o yaml
    
    # Verify RestorePoint and snapshot data before proceeding
    verify_restore_point "${restore_point}"
    
    local restore_action_name
    restore_action_name=$(create_restore_action "${restore_point}")
    wait_for_restore "${restore_action_name}"
    wait_for_app_ready
    verify_restore
    
    log_info "Application restore completed successfully!"
}

main "$@"
