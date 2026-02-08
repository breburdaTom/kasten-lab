#!/usr/bin/env bash
# ==============================================================================
# Script: create-policy.sh
# Description: Creates Kasten K10 backup policy
# ==============================================================================

set -euo pipefail

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"

echo "[INFO] Creating backup policy..."

# Ensure annotations are set (idempotent)
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
    k10.kasten.io/is-snapshot-class=true --overwrite 2>/dev/null || true
kubectl annotate storageclass csi-hostpath-sc \
    k10.kasten.io/volume-snapshot-class=csi-hostpath-snapclass --overwrite 2>/dev/null || true

# Delete existing policy if present
kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" 2>/dev/null || true

# Create policy
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: ${POLICY_NAME}
  namespace: ${K10_NAMESPACE}
spec:
  comment: "Backup policy for ${APP_NAMESPACE}"
  frequency: "@onDemand"
  actions:
    - action: backup
  selector:
    matchLabels:
      k10.kasten.io/appNamespace: ${APP_NAMESPACE}
EOF

echo "[INFO] Policy created!"
kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
