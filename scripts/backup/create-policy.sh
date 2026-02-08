#!/usr/bin/env bash
# ==============================================================================
# Script: create-policy.sh
# Description: Creates Kasten K10 backup policy for the test application
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
APP_NAMESPACE="${APP_NAMESPACE:-test-app}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-policy}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Create backup policy
create_policy() {
    log_info "Creating backup policy '${POLICY_NAME}'..."
    
    # Check if policy already exists
    if kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Policy '${POLICY_NAME}' already exists, deleting..."
        kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
        sleep 5
    fi
    
    # Create the policy
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
      backupParameters:
        filters:
          includeClusterResources: []
  retention:
    hourly: 24
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 5
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - ${APP_NAMESPACE}
EOF
    
    log_info "Backup policy created"
}

# Verify policy
verify_policy() {
    log_info "Verifying backup policy..."
    
    # Wait for policy to be created
    sleep 5
    
    # Show policy details
    log_info "Policy details:"
    kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o yaml
    
    # Verify policy is valid
    local validation
    validation=$(kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.validation}' 2>/dev/null || echo "pending")
    
    if [[ "${validation}" == "error" ]]; then
        log_error "Policy validation failed!"
        kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.error}'
        exit 1
    fi
    
    log_info "Policy validation status: ${validation}"
}

# Main execution
main() {
    log_info "Starting backup policy creation..."
    
    create_policy
    verify_policy
    
    log_info "Backup policy creation completed successfully!"
}

main "$@"
