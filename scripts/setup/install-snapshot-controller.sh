#!/usr/bin/env bash
# ==============================================================================
# Script: install-snapshot-controller.sh
# Description: Installs the CSI Snapshot Controller and CRDs
# ==============================================================================

set -euo pipefail

SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.0.1}"
SNAPSHOTTER_BASE_URL="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Debug helper - shows current state of snapshot-controller resources
debug_snapshot_state() {
    echo "  [DEBUG] === Deployment ==="
    kubectl get deployment -n kube-system snapshot-controller -o wide 2>/dev/null || echo "  [DEBUG] Deployment not found"
    echo "  [DEBUG] === Pods (all with 'snapshot' in name) ==="
    kubectl get pods -n kube-system 2>/dev/null | grep -i snapshot || echo "  [DEBUG] No snapshot pods"
    echo "  [DEBUG] === Recent Events ==="
    kubectl get events -n kube-system --sort-by='.lastTimestamp' 2>/dev/null | grep -i snapshot | tail -5 || echo "  [DEBUG] No events"
}

# Wait for condition with timeout and debug output
wait_for_condition() {
    local condition="$1" timeout="${2:-300}" interval="${3:-10}" description="${4:-condition}"
    local elapsed=0
    
    log_info "Waiting for ${description} (timeout: ${timeout}s)"
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition" 2>/dev/null; then
            log_info "${description} - ready after ${elapsed}s"
            return 0
        fi
        debug_snapshot_state
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Still waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description} after ${timeout}s"
    debug_snapshot_state
    return 1
}

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
    
    # Show deployment selector for debugging label issues
    log_info "Deployment pod selector:"
    kubectl get deployment -n kube-system snapshot-controller -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null && echo ""
    
    # Primary wait: use kubectl wait for deployment availability (most reliable)
    log_info "Waiting for deployment to be available..."
    if ! kubectl wait --for=condition=available deployment/snapshot-controller -n kube-system --timeout=600s 2>/dev/null; then
        log_error "Deployment did not become available"
        kubectl describe deployment -n kube-system snapshot-controller 2>/dev/null || true
        return 1
    fi
    log_info "Deployment is available"
    
    # Secondary wait: verify pods are Running (handles both common label patterns)
    wait_for_condition \
        "kubectl get pods -n kube-system -l app.kubernetes.io/name=snapshot-controller -o jsonpath='{.items[*].status.phase}' | grep -q Running || \
         kubectl get pods -n kube-system -l app=snapshot-controller -o jsonpath='{.items[*].status.phase}' | grep -q Running" \
        120 10 "snapshot-controller pods Running"
    
    # Verify CRDs
    log_info "Verifying CRDs..."
    kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io
    kubectl get crd volumesnapshotcontents.snapshot.storage.k8s.io
    kubectl get crd volumesnapshots.snapshot.storage.k8s.io
    
    # Final status
    log_info "Snapshot Controller pods:"
    kubectl get pods -n kube-system -o wide 2>/dev/null | grep -i snapshot || true
    
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
