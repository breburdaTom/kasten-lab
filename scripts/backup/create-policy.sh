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
PROFILE_NAME="${PROFILE_NAME:-k10-local-profile}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

verify_prerequisites() {
    log_info "Verifying prerequisites..."
    
    # Check VolumeSnapshotClass exists and has Kasten annotation
    log_info "Checking VolumeSnapshotClass..."
    local vsc_count
    vsc_count=$(kubectl get volumesnapshotclass -o jsonpath='{.items[*].metadata.annotations.k10\.kasten\.io/is-snapshot-class}' 2>/dev/null | grep -c "true" || echo "0")
    
    if [[ "$vsc_count" == "0" ]]; then
        log_warn "No VolumeSnapshotClass with Kasten annotation found. Attempting to annotate..."
        for vsc in $(kubectl get volumesnapshotclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            kubectl annotate volumesnapshotclass "${vsc}" k10.kasten.io/is-snapshot-class=true --overwrite 2>/dev/null || true
            log_info "Annotated VolumeSnapshotClass: ${vsc}"
        done
    else
        log_info "Found ${vsc_count} VolumeSnapshotClass(es) with Kasten annotation"
    fi
    
    # Check if Location Profile exists
    log_info "Checking Location Profile..."
    if ! kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Location Profile '${PROFILE_NAME}' not found. Creating it..."
        create_location_profile
    else
        log_info "Location Profile '${PROFILE_NAME}' exists"
    fi
    
    log_info "Prerequisites verified"
}

create_location_profile() {
    log_info "Creating Location Profile '${PROFILE_NAME}'..."
    
    # Create PVC for the profile
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PROFILE_NAME}-pvc
  namespace: ${K10_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: csi-hostpath-sc
EOF
    
    # Wait for PVC to be bound
    log_info "Waiting for PVC to be bound..."
    kubectl wait --for=jsonpath='{.status.phase}'=Bound \
        pvc/${PROFILE_NAME}-pvc -n ${K10_NAMESPACE} --timeout=120s || {
        log_error "PVC failed to bind"
        kubectl get pvc ${PROFILE_NAME}-pvc -n ${K10_NAMESPACE} -o yaml
        return 1
    }
    
    # Create the Location Profile
    cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: ${PROFILE_NAME}
  namespace: ${K10_NAMESPACE}
spec:
  type: Location
  locationSpec:
    credential:
      secretType: ""
    type: FileStore
    fileStore:
      claimName: ${PROFILE_NAME}-pvc
EOF
    
    # Wait for profile validation
    sleep 5
    local validation
    validation=$(kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" \
        -o jsonpath='{.status.validation}' 2>/dev/null || echo "pending")
    
    if [[ "${validation}" != "Success" ]]; then
        log_warn "Profile validation status: ${validation}"
        kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" -o yaml
    else
        log_info "Location Profile created and validated successfully"
    fi
}

create_policy() {
    log_info "Creating backup policy '${POLICY_NAME}'..."
    
    if kubectl get policy "${POLICY_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Policy '${POLICY_NAME}' already exists, deleting..."
        kubectl delete policy "${POLICY_NAME}" -n "${K10_NAMESPACE}"
        sleep 5
    fi
    
    # Create policy with profile reference for Kanister operations
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
        profile:
          name: ${PROFILE_NAME}
          namespace: ${K10_NAMESPACE}
  selector:
    matchLabels:
      k10.kasten.io/appNamespace: ${APP_NAMESPACE}
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
    verify_prerequisites
    create_policy
    verify_policy
    log_info "Backup policy creation completed successfully!"
}

main "$@"
