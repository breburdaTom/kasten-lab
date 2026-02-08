#!/usr/bin/env bash
# ==============================================================================
# Script: install-kasten.sh
# Description: Installs Kasten K10 using Helm
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
K10_VERSION="${K10_VERSION:-}"  # Empty means latest
HELM_RELEASE_NAME="k10"
READY_TIMEOUT="${KASTEN_READY_TIMEOUT:-600}"

# Colors and logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

wait_for_condition() {
    local condition="$1" timeout="${2:-300}" interval="${3:-10}" description="${4:-condition}"
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

add_helm_repo() {
    log_info "Adding Kasten Helm repository..."
    helm repo add kasten https://charts.kasten.io/ || true
    helm repo update
    log_info "Helm repository added and updated"
}

create_namespace() {
    log_info "Creating namespace '${K10_NAMESPACE}'..."
    kubectl create namespace "${K10_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    log_info "Namespace created"
}

install_k10() {
    log_info "Installing Kasten K10..."
    
    local helm_cmd="install"
    if helm status "${HELM_RELEASE_NAME}" -n "${K10_NAMESPACE}" &>/dev/null; then
        log_warn "Kasten K10 is already installed, upgrading..."
        helm_cmd="upgrade"
    fi
    
    local helm_args=(
        "${helm_cmd}" "${HELM_RELEASE_NAME}" "kasten/k10"
        "--namespace=${K10_NAMESPACE}"
        "--set" "eula.accept=true"
        "--set" "eula.company=demo"
        "--set" "eula.email=demo@example.com"
        "--set" "auth.tokenAuth.enabled=true"
        "--set" "injectKanisterSidecar.enabled=true"
        "--set" "global.persistence.storageClass=csi-hostpath-sc"
    )
    
    if [[ -n "${K10_VERSION}" ]]; then
        log_info "Installing specific version: ${K10_VERSION}"
        helm_args+=("--version=${K10_VERSION}")
    else
        log_info "Installing latest version"
    fi
    
    helm "${helm_args[@]}"
    log_info "Kasten K10 Helm chart installed"
}

wait_for_k10_ready() {
    log_info "Waiting for Kasten K10 to be ready (timeout: ${READY_TIMEOUT}s)..."
    
    wait_for_condition \
        "kubectl get pods -n ${K10_NAMESPACE} --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l | grep -q '^0$'" \
        "${READY_TIMEOUT}" 15 "all K10 pods to be running"
    
    wait_for_condition \
        "kubectl get pods -n ${K10_NAMESPACE} -l app=gateway --no-headers 2>/dev/null | grep -q '1/1.*Running'" \
        120 10 "K10 gateway pod"
    
    log_info "Kasten K10 is ready"
}

annotate_snapshot_class() {
    log_info "Annotating VolumeSnapshotClass for Kasten..."
    
    for vsc in $(kubectl get volumesnapshotclass -o jsonpath='{.items[*].metadata.name}'); do
        log_info "Annotating VolumeSnapshotClass: ${vsc}"
        kubectl annotate volumesnapshotclass "${vsc}" k10.kasten.io/is-snapshot-class=true --overwrite || true
    done
    log_info "VolumeSnapshotClasses annotated"
}

verify_installation() {
    log_info "Verifying Kasten K10 installation..."
    
    log_info "Kasten K10 pods:"; kubectl get pods -n "${K10_NAMESPACE}"
    log_info "Kasten K10 services:"; kubectl get svc -n "${K10_NAMESPACE}"
    log_info "Kasten K10 deployments:"; kubectl get deployments -n "${K10_NAMESPACE}"
    log_info "Kasten CRDs:"; kubectl get crd | grep kasten || true
    
    log_info "Kasten K10 installation verified"
}

print_access_info() {
    log_info "=============================================="
    log_info "Kasten K10 Installation Complete!"
    log_info "=============================================="
    log_info ""
    log_info "To access the K10 dashboard locally, run:"
    log_info "  kubectl --namespace ${K10_NAMESPACE} port-forward service/gateway 8080:80"
    log_info ""
    log_info "Then open: http://127.0.0.1:8080/k10/#/"
    log_info ""
    log_info "To get the authentication token:"
    log_info "  kubectl -n ${K10_NAMESPACE} create token k10-k10 --duration=24h"
    log_info "=============================================="
}

main() {
    log_info "Starting Kasten K10 installation..."
    
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed. Please install it first."
        exit 1
    fi
    
    add_helm_repo
    create_namespace
    install_k10
    wait_for_k10_ready
    annotate_snapshot_class
    verify_installation
    print_access_info
    
    log_info "Kasten K10 installation completed successfully!"
}

main "$@"
