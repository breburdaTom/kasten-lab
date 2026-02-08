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

echo "[INFO] Triggering backup..."

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

echo "[INFO] Waiting for backup to complete (timeout: ${TIMEOUT}s)..."

# Wait for backup
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
    # Get RunAction state
    run_state=$(kubectl get runaction "${RUN_ACTION}" -n "${K10_NAMESPACE}" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "Pending")
    
    # Get BackupAction info
    ba_state=$(kubectl get backupactions -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
        --all-namespaces -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "")
    
    echo "[INFO] RunAction: ${run_state} | BackupAction: ${ba_state:-waiting} | ${elapsed}s"
    
    if [[ "$ba_state" == "Complete" ]]; then
        echo "[INFO] Backup completed successfully!"
        exit 0
    fi
    
    if [[ "$ba_state" == "Failed" ]]; then
        echo "[ERROR] Backup failed!"
        kubectl get backupactions -l "k10.kasten.io/runActionName=${RUN_ACTION}" \
            --all-namespaces -o yaml
        exit 1
    fi
    
    sleep 15
    elapsed=$((elapsed + 15))
done

echo "[ERROR] Backup timed out!"
exit 1
