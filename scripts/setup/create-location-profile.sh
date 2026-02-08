#!/usr/bin/env bash
# ==============================================================================
# Script: create-location-profile.sh
# Description: Creates a Location Profile for Kasten K10 backup operations
#              Uses a file-based profile suitable for lab/demo environments
# ==============================================================================

set -euo pipefail

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
PROFILE_NAME="${PROFILE_NAME:-k10-local-profile}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

create_profile_pvc() {
    log_info "Creating PVC for Location Profile storage..."
    
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
        pvc/${PROFILE_NAME}-pvc -n ${K10_NAMESPACE} --timeout=120s
    
    log_info "PVC created and bound"
}

create_location_profile() {
    log_info "Creating Location Profile '${PROFILE_NAME}'..."
    
    # Create a file-based Location Profile using the Kasten repository server
    # This is suitable for lab/demo environments
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
    
    log_info "Location Profile created"
}

verify_profile() {
    log_info "Verifying Location Profile..."
    sleep 5
    
    local validation
    validation=$(kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" \
        -o jsonpath='{.status.validation}' 2>/dev/null || echo "pending")
    
    if [[ "${validation}" == "Success" ]]; then
        log_info "Location Profile validation: ${validation}"
    else
        log_warn "Location Profile validation: ${validation}"
        log_warn "Profile details:"
        kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" -o yaml
    fi
    
    log_info "Profile status:"
    kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" -o wide
}

main() {
    log_info "Starting Location Profile creation..."
    
    # Check if profile already exists
    if kubectl get profile "${PROFILE_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Profile '${PROFILE_NAME}' already exists"
        verify_profile
        return 0
    fi
    
    create_profile_pvc
    create_location_profile
    verify_profile
    
    log_info "Location Profile creation completed successfully!"
}

main "$@"
