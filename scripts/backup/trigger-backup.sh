#!/usr/bin/env bash
# ==============================================================================
# Script: trigger-backup.sh
# Description: Triggers a manual backup using Kasten K10
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"
TIMEOUT="${BACKUP_TIMEOUT:-600}"

log_info "Triggering backup for policy '${POLICY_NAME}'..."

# Verify Kasten K10 executor is ready
log_info "Checking Kasten K10 readiness..."
if ! kubectl get pods -n "${K10_NAMESPACE}" --no-headers 2>/dev/null | grep -iE "executor.*Running|Running.*executor" | grep -q .; then
    log_error "Kasten executor pods are not running"
    kubectl get pods -n "${K10_NAMESPACE}" 2>/dev/null || echo "  No pods found"
    exit 1
fi
log_info "Kasten K10 executor is ready"

# Verify policy exists before triggering
if ! kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
    echo "[ERROR] Policy '${POLICY_NAME}' not found in namespace '${K10_NAMESPACE}'"
    echo "[INFO] Available policies:"
    kubectl get policies -n "${K10_NAMESPACE}" 2>/dev/null || echo "  None found"
    exit 1
fi
echo "[INFO] Policy '${POLICY_NAME}' found"

# Create RunAction
RUN_ACTION="manual-backup-$(date +%Y%m%d%H%M%S)"
cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  name: ${RUN_ACTION}
  namespace: ${K10_NAMESPACE}
spec:
  subject:
    kind: Policy
    name: ${POLICY_NAME}
    namespace: ${K10_NAMESPACE}
EOF

# Verify RunAction was created
if ! kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" &>/dev/null; then
    echo "[ERROR] Failed to create RunAction '${RUN_ACTION}'"
    exit 1
fi
echo "[INFO] RunAction '${RUN_ACTION}' created successfully"
echo "[INFO] Waiting for backup to complete (timeout: ${TIMEOUT}s)..."

# Wait for backup
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
    # Batch fetch RunAction and BackupAction info to reduce kubectl calls
    combined=$(kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" -o json 2>/dev/null | \
        jq -r '.status.state // "Pending"' 2>/dev/null) || combined="Pending"
    run_state="${combined}"

    ba_info=$(kubectl get backupactions.actions.kio.kasten.io \
        -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
        --all-namespaces \
        -o jsonpath='{.items[0].metadata.name},{.items[0].status.state},{.items[0].status.progress}' 2>/dev/null || echo "")
    
    if [[ -n "$ba_info" && "$ba_info" != ",," ]]; then
        IFS=',' read -r ba_name ba_state ba_progress <<< "$ba_info"
        echo "[INFO] RunAction: ${run_state} | BackupAction: ${ba_name} (${ba_state:-pending}, ${ba_progress:-0}%) | ${elapsed}s"
        
        if [[ "$ba_state" == "Complete" ]]; then
            echo "[INFO] Backup completed successfully!"
            
            # Verify VolumeSnapshotContents are ready before declaring success
            echo "[INFO] Verifying VolumeSnapshotContents are ready..."
            vsc_ready=0
            for vsc_check in {1..12}; do
                # Fetch once and reuse counts
                vsc_json=$(kubectl get volumesnapshotcontents -o json 2>/dev/null || echo '{}')
                total_count=$(echo "$vsc_json" | jq '.items | length' 2>/dev/null || echo 0)
                if [[ -z "$total_count" || "$total_count" == "null" ]]; then total_count=0; fi
                if [[ "$total_count" -eq 0 ]]; then
                    echo "[WARN] No VolumeSnapshotContents found yet (${vsc_check}/12). Waiting..."
                    sleep 5
                    continue
                fi
                ready_count=$(echo "$vsc_json" | jq '[.items[] | select(.status.readyToUse==true)] | length' 2>/dev/null || echo 0)
                if [[ "$ready_count" -eq "$total_count" ]]; then
                    echo "[INFO] All VolumeSnapshotContents are ready (${ready_count}/${total_count})"
                    vsc_ready=1
                    break
                fi
                echo "[INFO] Waiting for VolumeSnapshotContents to be ready (${ready_count}/${total_count})..."
                sleep 5
            done
            
            if [[ "${vsc_ready}" -eq 0 ]]; then
                echo "[WARN] VolumeSnapshotContents may not be fully ready"
                kubectl get volumesnapshotcontents -o custom-columns='NAME:.metadata.name,READY:.status.readyToUse' 2>/dev/null || true
            fi
            
            # Show RestorePoint info
            echo "[INFO] RestorePoints created:"
            kubectl get restorepoints -n "${APP_NAMESPACE}" 2>/dev/null || echo "  None found"
            
            exit 0
        fi
        
        if [[ "$ba_state" == "Failed" ]]; then
            echo "[ERROR] Backup failed!"
            kubectl get backupactions.actions.kio.kasten.io \
                -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
                --all-namespaces -o yaml
            exit 1
        fi
    else
        echo "[INFO] RunAction: ${run_state} | BackupAction: waiting... | ${elapsed}s"
    fi
    
    sleep 15
    elapsed=$((elapsed + 15))
done

echo "[ERROR] Backup timed out after ${TIMEOUT}s!"
echo "[INFO] RunAction details:"
kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" -o yaml
echo "[INFO] BackupAction details:"
kubectl get backupactions.actions.kio.kasten.io \
    -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
    --all-namespaces -o yaml 2>/dev/null || echo "  No BackupAction found"
echo "[INFO] Kasten executor pod status:"
kubectl get pods -n "${K10_NAMESPACE}" -l component=executor 2>/dev/null || echo "  No executor pods found"
exit 1
