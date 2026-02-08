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
    local debug_cmd="${5:-}"
    
    local elapsed=0
    log_info "Starting wait for ${description} (timeout: ${timeout}s, interval: ${interval}s)"
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            log_info "${description} - condition met after ${elapsed}s"
            return 0
        fi
        
        # Run debug command if provided to show current state
        if [[ -n "$debug_cmd" ]]; then
            log_info "Debug output for ${description}:"
            eval "$debug_cmd" 2>&1 | while IFS= read -r line; do
                echo "  [DEBUG] $line"
            done
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Waiting for ${description}... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for ${description} after ${timeout}s"
    # Final debug output on failure
    if [[ -n "$debug_cmd" ]]; then
        log_error "Final state before timeout:"
        eval "$debug_cmd" 2>&1 | while IFS= read -r line; do
            echo "  [DEBUG] $line"
        done
    fi
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
    
    # First, check if the deployment exists
    log_info "Checking snapshot-controller deployment status..."
    kubectl get deployment -n kube-system snapshot-controller -o wide 2>/dev/null || log_warn "Deployment not found yet"
    
    # Check for any pods with the label (including non-running)
    log_info "Current pods with app=snapshot-controller label:"
    kubectl get pods -n kube-system -l app=snapshot-controller -o wide 2>/dev/null || log_warn "No pods found with label"
    
    # Wait for controller pods to be ready with enhanced debugging
    # Increased timeout to 600s (10 minutes) for slower environments
    wait_for_condition \
        "kubectl get pods -n kube-system -l app=snapshot-controller --no-headers 2>/dev/null | grep -q Running" \
        600 \
        10 \
        "snapshot-controller pods" \
        "kubectl get pods -n kube-system -l app=snapshot-controller -o wide 2>/dev/null; kubectl get events -n kube-system --field-selector involvedObject.name=snapshot-controller --sort-by='.lastTimestamp' 2>/dev/null | tail -5"
    
    # Additional verification: ensure pods are actually Ready (not just Running)
    log_info "Verifying pods are fully ready..."
    wait_for_condition \
        "kubectl get pods -n kube-system -l app=snapshot-controller -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" \
        120 \
        10 \
        "snapshot-controller pods Ready condition" \
        "kubectl get pods -n kube-system -l app=snapshot-controller -o jsonpath='{range .items[*]}{.metadata.name}: Ready={.status.conditions[?(@.type==\"Ready\")].status}, Phase={.status.phase}{\"\\n\"}{end}' 2>/dev/null"
    
    # Verify CRDs are installed
    log_info "Verifying CRDs..."
    kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io
    kubectl get crd volumesnapshotcontents.snapshot.storage.k8s.io
    kubectl get crd volumesnapshots.snapshot.storage.k8s.io
    
    # Show controller pods
    log_info "Snapshot Controller pods:"
    kubectl get pods -n kube-system -l app=snapshot-controller -o wide
    
    # Show pod logs for additional debugging info
    log_info "Snapshot Controller pod logs (last 10 lines):"
    for pod in $(kubectl get pods -n kube-system -l app=snapshot-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        log_info "Logs from pod: $pod"
        kubectl logs -n kube-system "$pod" --tail=10 2>/dev/null || log_warn "Could not retrieve logs for $pod"
    done
    
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
