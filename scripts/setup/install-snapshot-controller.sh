#!/usr/bin/env bash
# ==============================================================================
# Script: install-snapshot-controller.sh
# Description: Installs the CSI Snapshot Controller and CRDs
# ==============================================================================

set -euo pipefail

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration - using external-snapshotter release
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.0.1}"
SNAPSHOTTER_BASE_URL="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Wait for condition with timeout
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-300}"
    local interval="${3:-5}"
    local description="${4:-condition}"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description}"
    return 1
}

# Install Snapshot CRDs
install_crds() {
    log_info "Installing VolumeSnapshot CRDs (version: ${SNAPSHOTTER_VERSION})..."
    
    # Install CRDs
    kubectl apply -f "${SNAPSHOTTER_BASE_URL}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
    kubectl apply -f "${SNAPSHOTTER_BASE_URL}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
    kubectl apply -f "${SNAPSHOTTER_BASE_URL}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"
    
    log_info "VolumeSnapshot CRDs installed"
}

# Install Snapshot Controller
install_controller() {
    log_info "Installing Snapshot Controller..."
    
    # Install RBAC
    kubectl apply -f "${SNAPSHOTTER_BASE_URL}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
    
    # Install Controller
    kubectl apply -f "${SNAPSHOTTER_BASE_URL}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
    
    log_info "Snapshot Controller deployment applied"
}

# Verify installation
verify_installation() {
    log_info "Verifying Snapshot Controller installation..."
    
    # Wait for controller pods to be ready
    wait_for_condition \
        "kubectl get pods -n kube-system -l app=snapshot-controller --no-headers 2>/dev/null | grep -q Running" \
        300 \
        5 \
        "snapshot-controller pods"
    
    # Verify CRDs are installed
    log_info "Verifying CRDs..."
    kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io
    kubectl get crd volumesnapshotcontents.snapshot.storage.k8s.io
    kubectl get crd volumesnapshots.snapshot.storage.k8s.io
    
    # Show controller pods
    log_info "Snapshot Controller pods:"
    kubectl get pods -n kube-system -l app=snapshot-controller
    
    log_info "Snapshot Controller installation verified"
}

# Main execution
main() {
    log_info "Starting Snapshot Controller installation..."
    
    install_crds
    install_controller
    verify_installation
    
    log_info "Snapshot Controller installation completed successfully!"
}

main "$@"
