#!/usr/bin/env bash
# ==============================================================================
# Script: install-kind.sh
# Description: Creates a Kind (Kubernetes in Docker) cluster for Kasten K10 demo
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-kasten-demo}"
KIND_CONFIG="${PROJECT_ROOT}/manifests/kind-config.yaml"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

check_existing_cluster() {
    kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

create_cluster() {
    log_info "Creating Kind cluster '${CLUSTER_NAME}'..."
    
    if [[ -f "${KIND_CONFIG}" ]]; then
        log_info "Using config file: ${KIND_CONFIG}"
        kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 5m
    else
        log_warn "Config file not found, using default configuration"
        kind create cluster --name "${CLUSTER_NAME}" --wait 5m
    fi
    log_info "Cluster created successfully"
}

verify_cluster() {
    log_info "Verifying cluster is ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_info "Cluster nodes:"
    kubectl get nodes -o wide
    
    log_info "Cluster info:"
    kubectl cluster-info
}

main() {
    log_info "Starting Kind cluster installation..."
    
    for cmd in kind kubectl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is not installed. Please install it first."
            exit 1
        fi
    done
    
    if check_existing_cluster; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists, deleting..."
        kind delete cluster --name "${CLUSTER_NAME}"
    fi
    
    create_cluster
    verify_cluster
    
    log_info "Kind cluster installation completed successfully!"
}

main "$@"
