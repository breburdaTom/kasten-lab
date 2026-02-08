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

# Ensure the base snapshot class has Retain policy
echo "[INFO] Ensuring VolumeSnapshotClass deletionPolicy is Retain..."
kubectl patch volumesnapshotclass csi-hostpath-snapclass \
    --type='json' \
    -p='[{"op": "replace", "path": "/deletionPolicy", "value":"Retain"}]' 2>/dev/null || true

# Pre-create the Kasten clone snapshot class with Retain policy
# This prevents Kasten from creating it with Delete policy
echo "[INFO] Creating/patching Kasten clone snapshot class with Retain policy..."
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: k10-clone-csi-hostpath-snapclass
  labels:
    k10.kasten.io/isCloneClass: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Retain
EOF

# Delete existing policy if present
kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" 2>/dev/null || true

# Create policy
# NOTE: Kasten K10 policies select applications by namespace, not by label selector
# The selector.matchExpressions with k10.kasten.io/appNamespace is the correct way
# to target a specific namespace for backup
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
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - ${APP_NAMESPACE}
EOF

echo "[INFO] Policy created!"
kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
