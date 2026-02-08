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

verify_prerequisites() {
    log_info "Verifying prerequisites..."
    
    # Check VolumeSnapshotClass exists and has Kasten annotation
    log_info "Checking VolumeSnapshotClass configuration..."
    kubectl get volumesnapshotclass -o wide 2>/dev/null || {
        log_error "No VolumeSnapshotClasses found! CSI snapshots won't work."
        exit 1
    }
    
    # Check for Kasten annotation on VolumeSnapshotClass
    local vsc_with_annotation
    vsc_with_annotation=$(kubectl get volumesnapshotclass -o jsonpath='{.items[?(@.metadata.annotations.k10\.kasten\.io/is-snapshot-class=="true")].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$vsc_with_annotation" ]]; then
        log_warn "No VolumeSnapshotClass with Kasten annotation found. Annotating csi-hostpath-snapclass..."
        kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
            k10.kasten.io/is-snapshot-class=true --overwrite 2>/dev/null || {
            log_error "Failed to annotate VolumeSnapshotClass"
            exit 1
        }
    else
        log_info "VolumeSnapshotClass with Kasten annotation: ${vsc_with_annotation}"
    fi
    
    # Verify CSI driver is registered
    log_info "Checking CSI driver..."
    if ! kubectl get csidriver hostpath.csi.k8s.io &>/dev/null; then
        log_error "CSI driver 'hostpath.csi.k8s.io' not found!"
        exit 1
    fi
    log_info "CSI driver is registered"
    
    # Verify StorageClass exists
    log_info "Checking StorageClass..."
    if ! kubectl get storageclass csi-hostpath-sc &>/dev/null; then
        log_error "StorageClass 'csi-hostpath-sc' not found!"
        exit 1
    fi
    log_info "StorageClass exists"
    
    # Show current configuration
    log_info "Current VolumeSnapshotClass:"
    kubectl get volumesnapshotclass csi-hostpath-snapclass -o yaml | grep -A5 "metadata:" || true
    
    log_info "Prerequisites verified"
}

create_policy() {
    log_info "Creating backup policy '${POLICY_NAME}'..."
    
    if kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Policy '${POLICY_NAME}' already exists, deleting..."
        kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
        sleep 5
    fi
    
    # Create simple backup policy - CSI snapshots don't need a profile
    # The profile is only needed for export operations
    cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: ${POLICY_NAME}
  namespace: ${K10_NAMESPACE}
spec:
  comment: "Backup policy for PostgreSQL in ${APP_NAMESPACE}"
  frequency: "@onDemand"
  actions:
    - action: backup
  selector:
    matchLabels:
      k10.kasten.io/appNamespace: ${APP_NAMESPACE}
EOF
    log_info "Backup policy created"
}

verify_policy() {
    log_info "Verifying backup policy..."
    sleep 5
    
    local validation
    validation=$(kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o jsonpath='{.status.validation}' 2>/dev/null || echo "pending")
    
    if [[ "${validation}" == "error" ]]; then
        log_error "Policy validation failed!"
        kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o yaml
        exit 1
    fi
    
    log_info "Policy validation status: ${validation}"
    log_info "Policy details:"
    kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" -o wide
}

main() {
    log_info "Starting backup policy creation..."
    verify_prerequisites
    create_policy
    verify_policy
    log_info "Backup policy creation completed successfully!"
}

main "$@"
