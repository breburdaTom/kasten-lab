#!/usr/bin/env bash
# ==============================================================================
# Script: install-csi-driver.sh
# Description: Installs the CSI Hostpath Driver for Kind cluster
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CSI_DRIVER_PATH="${PROJECT_ROOT}/csi-driver-host-path/deploy/kubernetes-latest"
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
    
    if [[ ! -d "${CSI_DRIVER_PATH}" ]]; then
        log_error "CSI driver path not found: ${CSI_DRIVER_PATH}"
        exit 1
    fi
    
    log_info "Using local CSI driver from: ${CSI_DRIVER_PATH}"
    (cd "${CSI_DRIVER_PATH}" && ./deploy.sh)
    log_info "CSI Hostpath Driver deployed"
}

create_storage_class() {
    log_info "Creating StorageClass '${STORAGE_CLASS_NAME}'..."
    
    if kubectl get storageclass "${STORAGE_CLASS_NAME}" &>/dev/null; then
        log_warn "StorageClass '${STORAGE_CLASS_NAME}' already exists, skipping creation"
        return 0
    fi
    
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
    log_info "StorageClass created"
}

create_snapshot_class() {
    log_info "Creating VolumeSnapshotClass for Kasten..."
    
    if [[ -f "${PROJECT_ROOT}/manifests/k10-clone-snapshotclass.yaml" ]]; then
        kubectl apply -f "${PROJECT_ROOT}/manifests/k10-clone-snapshotclass.yaml"
    else
        cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-hostpath-snapclass
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Delete
EOF
    fi
    log_info "VolumeSnapshotClass created"
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
    
    log_info "CSI Driver installation verified"
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
