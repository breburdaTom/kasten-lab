#!/usr/bin/env bash
# ==============================================================================
# Script: install-snapshot-controller.sh
# Description: Installs the CSI Snapshot Controller and CRDs
# Compatible with CSI driver v1.14.x
# ==============================================================================

set -euo pipefail

# Use v7.0.2 for better compatibility with CSI driver v1.14.x
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v7.0.2}"
SNAPSHOTTER_BASE_URL="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

install_crds() {
    log_info "Installing VolumeSnapshot CRDs (version: ${SNAPSHOTTER_VERSION})..."
    local crd_base="${SNAPSHOTTER_BASE_URL}/client/config/crd"
    kubectl apply -f "${crd_base}/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
    kubectl apply -f "${crd_base}/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
    kubectl apply -f "${crd_base}/snapshot.storage.k8s.io_volumesnapshots.yaml"
    log_info "VolumeSnapshot CRDs installed"
}

install_controller() {
    log_info "Installing Snapshot Controller..."
    local deploy_base="${SNAPSHOTTER_BASE_URL}/deploy/kubernetes/snapshot-controller"
    kubectl apply -f "${deploy_base}/rbac-snapshot-controller.yaml"
    kubectl apply -f "${deploy_base}/setup-snapshot-controller.yaml"
    log_info "Snapshot Controller deployment applied"
}

verify_installation() {
    log_info "Verifying Snapshot Controller installation..."
    
    # Wait for deployment
    if ! kubectl wait --for=condition=available deployment/snapshot-controller -n kube-system --timeout=300s 2>/dev/null; then
        log_error "Snapshot Controller deployment failed"
        kubectl describe deployment -n kube-system snapshot-controller 2>/dev/null || true
        return 1
    fi
    
    # Verify CRDs exist
    log_info "Verifying CRDs..."
    kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io
    kubectl get crd volumesnapshotcontents.snapshot.storage.k8s.io
    kubectl get crd volumesnapshots.snapshot.storage.k8s.io
    
    # Show controller status
    log_info "Snapshot Controller pods:"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=snapshot-controller -o wide 2>/dev/null || \
    kubectl get pods -n kube-system | grep snapshot || true
    
    log_info "Snapshot Controller installation verified"
}

main() {
    log_info "Starting Snapshot Controller installation..."
    install_crds
    install_controller
    verify_installation
    log_info "Snapshot Controller installation completed successfully!"
}

main "$@"
