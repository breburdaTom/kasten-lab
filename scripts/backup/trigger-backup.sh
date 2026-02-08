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

echo "[INFO] Triggering backup for policy '${POLICY_NAME}'..."

# Verify policy exists before triggering
if ! kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
    echo "[ERROR] Policy '${POLICY_NAME}' does not exist in namespace '${K10_NAMESPACE}'"
    echo "[INFO] Available policies:"
    kubectl get policies -n "${K10_NAMESPACE}" --no-headers 2>/dev/null || echo "  (none found)"
    exit 1
fi

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

echo "[INFO] RunAction '${RUN_ACTION}' created"
echo "[INFO] Waiting for backup to complete (timeout: ${TIMEOUT}s)..."

# Wait for backup
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
    # Get RunAction state
    run_state=$(kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "Pending")
    
    # Get BackupAction info (search all namespaces with the runActionName label)
    ba_info=$(kubectl get backupactions.actions.kio.kasten.io \
        -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
        --all-namespaces \
        -o jsonpath='{.items[0].metadata.name},{.items[0].status.state},{.items[0].status.progress}' 2>/dev/null || echo "")
    
    if [[ -n "$ba_info" && "$ba_info" != ",," ]]; then
        IFS=',' read -r ba_name ba_state ba_progress <<< "$ba_info"
        echo "[INFO] RunAction: ${run_state} | BackupAction: ${ba_name} (${ba_state:-pending}, ${ba_progress:-0}%) | ${elapsed}s"
        
        if [[ "$ba_state" == "Complete" ]]; then
            echo "[INFO] Backup completed successfully!"
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
echo "[DEBUG] RunAction details:"
kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" -o yaml
echo "[DEBUG] BackupAction details:"
kubectl get backupactions.actions.kio.kasten.io \
    -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
    --all-namespaces -o yaml 2>/dev/null || echo "  (no BackupAction found)"
exit 1
