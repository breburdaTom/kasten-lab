#!/usr/bin/env bash
# ==============================================================================
# Script: install-csi-driver.sh
# Description: Installs the CSI Hostpath Driver for Kind cluster
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# CSI Driver configuration - download from official repo
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-v1.15.0}"
CSI_DRIVER_REPO="https://github.com/kubernetes-csi/csi-driver-host-path"
CSI_DRIVER_DEPLOY_PATH="deploy/kubernetes-latest"
STORAGE_CLASS_NAME="csi-hostpath-sc"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

wait_for_condition() {
    local condition="$1" timeout="${2:-300}" interval="${3:-5}" description="${4:-condition}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then return 0; fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}

deploy_csi_driver() {
    log_info "Deploying CSI Hostpath Driver..."
    
    local tmp_dir="${PROJECT_ROOT}/.tmp/csi-driver-host-path"
    local deploy_path="${tmp_dir}/${CSI_DRIVER_DEPLOY_PATH}"
    
    # Download CSI driver
    log_info "Downloading CSI Hostpath Driver (version: ${CSI_DRIVER_VERSION})..."
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"
    git clone --depth 1 --branch "${CSI_DRIVER_VERSION}" "${CSI_DRIVER_REPO}" "${tmp_dir}"
    log_info "CSI Hostpath Driver downloaded to ${tmp_dir}"
    
    # Verify deploy path exists
    if [[ ! -d "${deploy_path}" ]]; then
        log_error "Deploy path not found: ${deploy_path}"
        log_error "Available directories:"
        ls -la "${tmp_dir}/deploy/" 2>/dev/null || true
        exit 1
    fi
    
    log_info "Running deploy script from: ${deploy_path}"
    (cd "${deploy_path}" && ./deploy.sh)
    
    # Cleanup
    log_info "Cleaning up temporary files..."
    rm -rf "${tmp_dir}"
    
    log_info "CSI Hostpath Driver deployed"
}

create_storage_class() {
    log_info "Creating StorageClass '${STORAGE_CLASS_NAME}'..."
    
    # Remove any existing default StorageClass annotation
    for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}'); do
        kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
    done
    
    # Create or update our StorageClass with Immediate binding (better for CI)
    # Include Kasten annotation to specify the VolumeSnapshotClass to use
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    # Tell Kasten which VolumeSnapshotClass to use for this StorageClass
    k10.kasten.io/volume-snapshot-class: csi-hostpath-snapclass
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
    log_info "StorageClass created with Kasten annotations"
}

create_snapshot_class() {
    log_info "Creating/Updating VolumeSnapshotClass for Kasten..."
    
    # The CSI hostpath driver deploy script creates a VolumeSnapshotClass named "csi-hostpath-snapclass"
    # We need to ensure it has the Kasten annotations
    
    # Wait a moment for the CSI driver to create its resources
    sleep 5
    
    # Check all VolumeSnapshotClasses
    log_info "Current VolumeSnapshotClasses:"
    kubectl get volumesnapshotclass -o wide 2>/dev/null || echo "No VolumeSnapshotClasses found"
    
    # Find VolumeSnapshotClass for hostpath driver
    local existing_vsc
    existing_vsc=$(kubectl get volumesnapshotclass -o jsonpath='{.items[?(@.driver=="hostpath.csi.k8s.io")].metadata.name}' 2>/dev/null | awk '{print $1}' || echo "")
    
    if [[ -n "$existing_vsc" && "$existing_vsc" != "" ]]; then
        log_info "Found existing VolumeSnapshotClass: ${existing_vsc}"
        # Annotate the existing one for Kasten
        kubectl annotate volumesnapshotclass "${existing_vsc}" \
            k10.kasten.io/is-snapshot-class=true --overwrite
        kubectl label volumesnapshotclass "${existing_vsc}" \
            k10.kasten.io/isCloneClass=true --overwrite 2>/dev/null || true
        
        # Update StorageClass to reference this VolumeSnapshotClass
        kubectl annotate storageclass "${STORAGE_CLASS_NAME}" \
            k10.kasten.io/volume-snapshot-class="${existing_vsc}" --overwrite 2>/dev/null || true
    else
        log_info "No existing VolumeSnapshotClass found, creating new one..."
        # Create with all required Kasten annotations
        cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-hostpath-snapclass
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
  labels:
    k10.kasten.io/isCloneClass: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Delete
EOF
        # Update StorageClass to reference this VolumeSnapshotClass
        kubectl annotate storageclass "${STORAGE_CLASS_NAME}" \
            k10.kasten.io/volume-snapshot-class=csi-hostpath-snapclass --overwrite 2>/dev/null || true
    fi
    
    # Verify the configuration
    log_info "Final VolumeSnapshotClass configuration:"
    kubectl get volumesnapshotclass -o wide
    
    log_info "VolumeSnapshotClass YAML:"
    kubectl get volumesnapshotclass -o yaml
    
    log_info "StorageClass annotations:"
    kubectl get storageclass "${STORAGE_CLASS_NAME}" -o yaml | grep -A10 "annotations:" || true
    
    log_info "VolumeSnapshotClass configured for Kasten"
}

verify_installation() {
    log_info "Verifying CSI Driver installation..."
    
    wait_for_condition \
        "kubectl get pods -l app.kubernetes.io/instance=hostpath.csi.k8s.io --all-namespaces --no-headers 2>/dev/null | grep -q Running" \
        180 5 "CSI driver pods"
    
    log_info "CSI Driver pods:"
    kubectl get pods -l app.kubernetes.io/instance=hostpath.csi.k8s.io --all-namespaces
    
    log_info "StorageClasses:"
    kubectl get storageclass
    
    log_info "VolumeSnapshotClasses:"
    kubectl get volumesnapshotclass
    
    log_info "CSI Drivers:"
    kubectl get csidrivers
    
    # Verify CSI driver capabilities
    log_info "CSI Driver capabilities:"
    kubectl get csidriver hostpath.csi.k8s.io -o yaml 2>/dev/null | grep -A20 "spec:" || true
    
    log_info "CSI Driver installation verified"
}

# Optional: Test CSI snapshot capability (not called by default)
# Usage: CSI_DRIVER_VERSION=v1.15.0 ./install-csi-driver.sh && ./install-csi-driver.sh test
test_snapshot_capability() {
    log_info "Testing CSI snapshot capability..."
    local ns="csi-snap-test-$"
    trap "kubectl delete namespace ${ns} --ignore-not-found=true &>/dev/null" EXIT
    
    kubectl create namespace "${ns}" &>/dev/null
    kubectl apply -n "${ns}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-pvc }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } }, storageClassName: ${STORAGE_CLASS_NAME} }
EOF
    kubectl wait -n "${ns}" --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc --timeout=60s || { log_error "PVC bind failed"; return 1; }
    
    local vsc=$(kubectl get volumesnapshotclass -o jsonpath='{.items[?(@.driver=="hostpath.csi.k8s.io")].metadata.name}' | awk '{print $1}')
    [[ -z "$vsc" ]] && { log_error "No VolumeSnapshotClass found"; return 1; }
    
    kubectl apply -n "${ns}" -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: test-snap }
spec: { volumeSnapshotClassName: ${vsc}, source: { persistentVolumeClaimName: test-pvc } }
EOF
    
    for i in {1..30}; do
        [[ "$(kubectl get volumesnapshot test-snap -n ${ns} -o jsonpath='{.status.readyToUse}' 2>/dev/null)" == "true" ]] && { log_info "Snapshot test passed!"; return 0; }
        sleep 2
    done
    log_error "Snapshot test failed"; return 1
}

main() {
    log_info "Starting CSI Hostpath Driver installation..."
    deploy_csi_driver
    create_storage_class
    create_snapshot_class
    verify_installation
    log_info "CSI Hostpath Driver installation completed successfully!"
}

main "$@"
