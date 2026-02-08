#!/usr/bin/env bash
# ==============================================================================
# Script: trigger-backup.sh
# Description: Triggers a manual backup using Kasten K10
# ==============================================================================

set -euo pipefail

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"
TIMEOUT="${BACKUP_TIMEOUT:-600}"

eecho "[INFO] Triggering backup for policy '${POLICY_NAME}'..."

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
kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" -o yaml
exit 1
