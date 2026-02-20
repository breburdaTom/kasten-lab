#!/usr/bin/env bash
# ==============================================================================
# Script: install-csi-driver.sh
# Description: Installs CSI Hostpath Driver for Kind cluster
# Based on: https://docs.kasten.io/latest/install/other/kind.html
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "[INFO] Installing CSI Hostpath Driver..."

# Clone CSI driver
cd "${PROJECT_ROOT}"
rm -rf csi-driver-host-path
git clone https://github.com/kubernetes-csi/csi-driver-host-path.git

# Deploy CSI driver
cd csi-driver-host-path
deploy_dir=$(ls -d deploy/kubernetes-* 2>/dev/null | sort -V | tail -1)
echo "[INFO] Using deploy directory: ${deploy_dir}"
./${deploy_dir}/deploy.sh

# Apply declarative StorageClass manifest (sets default via annotation)
echo "[INFO] Setting up StorageClass..."
kubectl apply -f "${PROJECT_ROOT}/manifests/cluster/csi/storageclass.yaml"

# Apply declarative VolumeSnapshotClass manifests
kubectl apply -f "${PROJECT_ROOT}/manifests/cluster/csi/volumesnapshotclass-default.yaml"
# Ensure StorageClass annotation is already in YAML; no imperative annotation needed

# Cleanup
cd "${PROJECT_ROOT}"
rm -rf csi-driver-host-path

echo "[INFO] CSI Driver installation complete!"
kubectl get storageclass
kubectl get volumesnapshotclass
