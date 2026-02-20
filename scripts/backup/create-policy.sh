#!/usr/bin/env bash
# ==============================================================================
# Script: create-policy.sh
# Description: Creates Kasten K10 backup policy
# ==============================================================================

set -euo pipefail

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"
POLICY_FILE="${POLICY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../manifests/app/postgres && pwd)/backup-policy.yaml}"

echo "[INFO] Creating backup policy..."

# Delete existing policy if present
kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" 2>/dev/null || true

# Create policy from canonical YAML file
# Allow overriding via POLICY_FILE env, defaulting to manifests/app/postgres/backup-policy.yaml
if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "[ERROR] Policy file not found: ${POLICY_FILE}" >&2
  exit 1
fi

# If APP_NAMESPACE or K10_NAMESPACE differ from defaults, allow envsubst templating when placeholders exist
# The canonical file can be plain YAML or a template using ${APP_NAMESPACE} and ${K10_NAMESPACE}
if grep -q '\${APP_NAMESPACE}\|\${K10_NAMESPACE}' "${POLICY_FILE}" 2>/dev/null; then
  APP_NAMESPACE="${APP_NAMESPACE}" K10_NAMESPACE="${K10_NAMESPACE}" envsubst < "${POLICY_FILE}" | kubectl apply -f -
else
  kubectl apply -f "${POLICY_FILE}"
fi

echo "[INFO] Policy created!"
kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
