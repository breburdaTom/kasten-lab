#!/usr/bin/env bash
# ==============================================================================
# Script: install-csi-driver.sh
# Description: Installs the CSI Hostpath Driver for Kind cluster with snapshot support
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# CSI Driver configuration
# Use compatible versions: CSI driver v1.14.x works well with snapshotter v7.x/v8.x
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-v1.14.0}"
CSI_DRIVER_REPO="https://github.com/kubernetes-csi/csi-driver-host-path"
STORAGE_CLASS_NAME="csi-hostpath-sc"
SNAPSHOT_CLASS_NAME="csi-hostpath-snapclass"

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

deploy_csi_driver() {
    log_info "Deploying CSI Hostpath Driver (version: ${CSI_DRIVER_VERSION})..."
    
    local tmp_dir="${PROJECT_ROOT}/.tmp/csi-driver-host-path"
    
    # Download CSI driver
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"
    git clone --depth 1 --branch "${CSI_DRIVER_VERSION}" "${CSI_DRIVER_REPO}" "${tmp_dir}"
    
    # Find the correct deploy path (varies by version)
    local deploy_path=""
    for path in "deploy/kubernetes-latest" "deploy/kubernetes-1.28" "deploy/kubernetes-1.27" "deploy/kubernetes-1.26"; do
        if [[ -d "${tmp_dir}/${path}" ]]; then
            deploy_path="${tmp_dir}/${path}"
            break
        fi
    done
    
    if [[ -z "$deploy_path" ]]; then
        log_error "No deploy path found. Available:"
        ls -la "${tmp_dir}/deploy/" 2>/dev/null || true
        exit 1
    fi
    
    log_info "Using deploy path: ${deploy_path}"
    
    # Deploy the CSI driver with snapshot support
    (cd "${deploy_path}" && ./deploy.sh)
    
    # Cleanup
    rm -rf "${tmp_dir}"
    log_info "CSI Hostpath Driver deployed"
}

get_csi_driver_name() {
    # Get the actual driver name registered by the CSI driver
    local driver_name
    driver_name=$(kubectl get csidriver -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "hostpath|csi-hostpath" | head -1 || echo "")
    
    if [[ -z "$driver_name" ]]; then
        # Default name used by csi-driver-host-path
        driver_name="hostpath.csi.k8s.io"
    fi
    
    echo "$driver_name"
}

create_storage_class() {
    local driver_name
    driver_name=$(get_csi_driver_name)
    log_info "Creating StorageClass '${STORAGE_CLASS_NAME}' with driver '${driver_name}'..."
    
    # Remove default annotation from other StorageClasses
    for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
    done
    
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    k10.kasten.io/volume-snapshot-class: ${SNAPSHOT_CLASS_NAME}
provisioner: ${driver_name}
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
    log_info "StorageClass created"
}

create_snapshot_class() {
    local driver_name
    driver_name=$(get_csi_driver_name)
    log_info "Creating VolumeSnapshotClass '${SNAPSHOT_CLASS_NAME}' with driver '${driver_name}'..."
    
    # Delete existing snapshot class if it exists with wrong driver
    kubectl delete volumesnapshotclass "${SNAPSHOT_CLASS_NAME}" 2>/dev/null || true
    
    cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ${SNAPSHOT_CLASS_NAME}
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
  labels:
    k10.kasten.io/isCloneClass: "true"
driver: ${driver_name}
deletionPolicy: Delete
EOF
    log_info "VolumeSnapshotClass created"
}

verify_installation() {
    log_info "Verifying CSI Driver installation..."
    
    # Wait for CSI driver pods
    wait_for_condition \
        "kubectl get pods --all-namespaces -o wide 2>/dev/null | grep -E 'csi-hostpath|hostpath' | grep -q Running" \
        180 5 "CSI driver pods"
    
    log_info "CSI Driver pods:"
    kubectl get pods --all-namespaces -o wide 2>/dev/null | grep -E 'csi-hostpath|hostpath' || true
    
    log_info "CSI Drivers registered:"
    kubectl get csidrivers
    
    log_info "StorageClasses:"
    kubectl get storageclass
    
    log_info "VolumeSnapshotClasses:"
    kubectl get volumesnapshotclass
    
    # Verify driver name matches
    local driver_name
    driver_name=$(get_csi_driver_name)
    local vsc_driver
    vsc_driver=$(kubectl get volumesnapshotclass "${SNAPSHOT_CLASS_NAME}" -o jsonpath='{.driver}' 2>/dev/null || echo "")
    
    if [[ "$driver_name" != "$vsc_driver" ]]; then
        log_warn "Driver mismatch! CSI: ${driver_name}, VolumeSnapshotClass: ${vsc_driver}"
        log_info "Recreating VolumeSnapshotClass with correct driver..."
        create_snapshot_class
    fi
    
    log_info "CSI Driver installation verified"
}

test_snapshot() {
    log_info "Testing CSI snapshot capability..."
    local test_ns="csi-test-${RANDOM}"
    
    # Cleanup function - delete test namespace at the end
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
  storageClassName: ${STORAGE_CLASS_NAME}
EOF
    
    # Wait for PVC to bind
    if ! kubectl wait -n "${test_ns}" --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc --timeout=60s; then
        log_error "Test PVC failed to bind"
        kubectl get pvc -n "${test_ns}" -o yaml
        cleanup_test
        return 1
    fi
    log_info "Test PVC bound successfully"
    
    # Create snapshot
    cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
  namespace: ${test_ns}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS_NAME}
  source:
    persistentVolumeClaimName: test-pvc
EOF
    
    # Wait for snapshot to be ready
    log_info "Waiting for snapshot to be ready..."
    for i in {1..30}; do
        local ready
        ready=$(kubectl get volumesnapshot test-snapshot -n "${test_ns}" -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
        if [[ "$ready" == "true" ]]; then
            log_info "Snapshot test PASSED! CSI snapshots are working."
            cleanup_test
            return 0
        fi
        
        # Check for errors
        local error
        error=$(kubectl get volumesnapshot test-snapshot -n "${test_ns}" -o jsonpath='{.status.error.message}' 2>/dev/null || echo "")
        if [[ -n "$error" ]]; then
            log_error "Snapshot error: ${error}"
            kubectl get volumesnapshotcontent -o yaml 2>/dev/null | tail -50 || true
            cleanup_test
            return 1
        fi
        
        sleep 2
    done
    
    log_error "Snapshot test FAILED - timeout waiting for snapshot"
    kubectl get volumesnapshot -n "${test_ns}" -o yaml
    kubectl get volumesnapshotcontent -o yaml 2>/dev/null | tail -30 || true
    cleanup_test
    return 1
}

main() {
    log_info "Starting CSI Hostpath Driver installation..."
    
    deploy_csi_driver
    
    # Wait for CSI driver to register
    sleep 10
    
    create_storage_class
    create_snapshot_class
    verify_installation
    
    # Run snapshot test to validate everything works
    if test_snapshot; then
        log_info "CSI Hostpath Driver installation completed successfully!"
    else
        log_error "CSI Driver installed but snapshot test failed!"
        log_error "Kasten K10 backups may not work correctly."
        exit 1
    fi
}

main "$@"
