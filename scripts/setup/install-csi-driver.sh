#!/usr/bin/env bash
# ==============================================================================
# Script: install-csi-driver.sh
# Description: Installs the CSI Hostpath Driver for Kind cluster with snapshot support
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# CSI Driver configuration
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-v1.14.0}"
CSI_DRIVER_REPO="https://github.com/kubernetes-csi/csi-driver-host-path"
TMP_DIR="${PROJECT_ROOT}/.tmp/csi-driver-host-path"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

wait_for_condition() {
    local condition="$1" timeout="${2:-300}" interval="${3:-5}" description="${4:-condition}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition" 2>/dev/null; then return 0; fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}

download_csi_driver() {
    log_info "Downloading CSI Hostpath Driver (version: ${CSI_DRIVER_VERSION})..."
    rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}"
    git clone --depth 1 --branch "${CSI_DRIVER_VERSION}" "${CSI_DRIVER_REPO}" "${TMP_DIR}"
    log_info "CSI Hostpath Driver downloaded"
}

deploy_csi_driver() {
    log_info "Deploying CSI Hostpath Driver..."
    
    # Find the correct deploy path (varies by version)
    local deploy_path=""
    for path in "deploy/kubernetes-latest" "deploy/kubernetes-1.28" "deploy/kubernetes-1.27" "deploy/kubernetes-1.26"; do
        if [[ -d "${TMP_DIR}/${path}" ]]; then
            deploy_path="${TMP_DIR}/${path}"
            break
        fi
    done
    
    if [[ -z "$deploy_path" ]]; then
        log_error "No deploy path found. Available:"
        ls -la "${TMP_DIR}/deploy/" 2>/dev/null || true
        exit 1
    fi
    
    log_info "Using deploy path: ${deploy_path}"
    (cd "${deploy_path}" && ./deploy.sh)
    log_info "CSI Hostpath Driver deployed"
}

setup_storage_class() {
    log_info "Setting up StorageClass..."
    
    # Remove default annotation from existing StorageClasses (e.g., 'standard' in Kind)
    for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        if [[ "$sc" != "csi-hostpath-sc" ]]; then
            log_info "Removing default annotation from StorageClass: ${sc}"
            kubectl patch storageclass "$sc" \
                -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
                2>/dev/null || true
        fi
    done
    
    # Apply the CSI driver's StorageClass from examples
    log_info "Applying CSI driver's StorageClass..."
    kubectl apply -f "${TMP_DIR}/examples/csi-storageclass.yaml"
    
    # Make it the default StorageClass
    log_info "Setting csi-hostpath-sc as default StorageClass..."
    kubectl patch storageclass csi-hostpath-sc \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    log_info "StorageClass configured"
}

setup_snapshot_class() {
    log_info "Setting up VolumeSnapshotClass..."
    
    # Apply the CSI driver's VolumeSnapshotClass from examples
    log_info "Applying CSI driver's VolumeSnapshotClass..."
    kubectl apply -f "${TMP_DIR}/examples/csi-snapshot-v1-class.yaml" 2>/dev/null || \
    kubectl apply -f "${TMP_DIR}/examples/csi-volumesnapshotclass.yaml" 2>/dev/null || {
        log_warn "No example snapshot class found, creating manually..."
        cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-hostpath-snapclass
driver: hostpath.csi.k8s.io
deletionPolicy: Delete
EOF
    }
    
    # Tell Kasten to use this VolumeSnapshotClass
    log_info "Annotating VolumeSnapshotClass for Kasten..."
    kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
        k10.kasten.io/is-snapshot-class=true --overwrite
    
    log_info "VolumeSnapshotClass configured for Kasten"
}

verify_installation() {
    log_info "Verifying CSI Driver installation..."
    
    # Wait for CSI driver pods
    wait_for_condition \
        "kubectl get pods --all-namespaces 2>/dev/null | grep -E 'csi-hostpath' | grep -q Running" \
        180 5 "CSI driver pods"
    
    log_info "CSI Driver pods:"
    kubectl get pods --all-namespaces | grep -E 'csi-hostpath' || true
    
    log_info "CSI Drivers registered:"
    kubectl get csidrivers
    
    log_info "StorageClasses:"
    kubectl get storageclass
    
    log_info "VolumeSnapshotClasses:"
    kubectl get volumesnapshotclass
    
    # Verify Kasten annotation
    local kasten_annotation
    kasten_annotation=$(kubectl get volumesnapshotclass csi-hostpath-snapclass \
        -o jsonpath='{.metadata.annotations.k10\.kasten\.io/is-snapshot-class}' 2>/dev/null || echo "")
    
    if [[ "$kasten_annotation" != "true" ]]; then
        log_error "Kasten annotation missing on VolumeSnapshotClass!"
        return 1
    fi
    
    log_info "CSI Driver installation verified"
}

test_snapshot() {
    log_info "Testing CSI snapshot capability..."
    local test_ns="csi-test-${RANDOM}"
    
    cleanup_test() {
        kubectl delete namespace "${test_ns}" --ignore-not-found=true --wait=false &>/dev/null || true
    }
    
    # Create test namespace and PVC
    kubectl create namespace "${test_ns}"
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: ${test_ns}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: csi-hostpath-sc
EOF
    
    # Wait for PVC to bind
    if ! kubectl wait -n "${test_ns}" --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc --timeout=60s; then
        log_error "Test PVC failed to bind"
        kubectl get pvc -n "${test_ns}" -o yaml
        cleanup_test
        return 1
    fi
    log_info "Test PVC bound successfully"
    
    # Create snapshot using the CSI driver's snapshot class
    cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
  namespace: ${test_ns}
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: test-pvc
EOF
    
    # Wait for snapshot to be ready
    log_info "Waiting for snapshot to be ready..."
    for i in {1..30}; do
        local ready
        ready=$(kubectl get volumesnapshot test-snapshot -n "${test_ns}" \
            -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
        if [[ "$ready" == "true" ]]; then
            log_info "Snapshot test PASSED! CSI snapshots are working."
            cleanup_test
            return 0
        fi
        sleep 2
    done
    
    log_error "Snapshot test FAILED - timeout waiting for snapshot"
    kubectl get volumesnapshot -n "${test_ns}" -o yaml
    cleanup_test
    return 1
}

cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "${TMP_DIR}"
}

main() {
    log_info "Starting CSI Hostpath Driver installation..."
    
    download_csi_driver
    deploy_csi_driver
    
    # Wait for CSI driver to register
    sleep 10
    
    setup_storage_class
    setup_snapshot_class
    verify_installation
    
    # Run snapshot test to validate everything works
    if test_snapshot; then
        log_info "CSI Hostpath Driver installation completed successfully!"
    else
        log_error "CSI Driver installed but snapshot test failed!"
        log_error "Kasten K10 backups may not work correctly."
        cleanup
        exit 1
    fi
    
    cleanup
}

main "$@"
