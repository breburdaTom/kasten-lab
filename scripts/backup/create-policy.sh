#!/usr/bin/env bash
# ==============================================================================
# Script: create-policy.sh
# Description: Creates Kasten K10 backup policy for the test application
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

create_policy() {
    log_info "Creating backup policy '${POLICY_NAME}'..."
    
    if kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Policy '${POLICY_NAME}' already exists, deleting..."
        kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
        sleep 5
    fi
    
    cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: ${POLICY_NAME}
  namespace: ${K10_NAMESPACE}
spec:
  comment: "Automated backup policy for PostgreSQL demo"
  frequency: "@onDemand"
  actions:
    - action: backup
  selector:
    resourceSelectors:
      - matchExpressions:
          - key: k10.kasten.io/appNamespace
            operator: In
            values:
              - ${APP_NAMESPACE}
EOF
    log_info "Backup policy created"
}

verify_policy() {
    log_info "Verifying backup policy..."
    sleep 5
    
    log_info "Policy details:"
    kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o yaml
    
    local validation
    validation=$(kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.validation}' 2>/dev/null || echo "pending")
    
    if [[ "${validation}" == "error" ]]; then
        log_error "Policy validation failed!"
        kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.error}'
        exit 1
    fi
    log_info "Policy validation status: ${validation}"
}

main() {
    log_info "Starting backup policy creation..."
    create_policy
    verify_policy
    log_info "Backup policy creation completed successfully!"
}

main "$@"
