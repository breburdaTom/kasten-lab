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

# Apply StorageClass and make it default
echo "[INFO] Setting up StorageClass..."
kubectl apply -f examples/csi-storageclass.yaml
kubectl patch storageclass standard \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
kubectl patch storageclass csi-hostpath-sc \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Apply VolumeSnapshotClass with Retain policy
# CRITICAL: The default CSI examples use Delete policy which causes snapshot data
# to be deleted when PVCs are deleted, making restore impossible
echo "[INFO] Setting up VolumeSnapshotClass with Retain policy..."
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-hostpath-snapclass
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
  labels:
    k10.kasten.io/isCloneClass: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Retain
EOF

# Also create the Kasten clone snapshot class with Retain policy
# Kasten creates this automatically but with Delete policy by default
echo "[INFO] Creating Kasten clone snapshot class with Retain policy..."
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: k10-clone-csi-hostpath-snapclass
  labels:
    k10.kasten.io/isCloneClass: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Retain
EOF

# Annotate StorageClass for Kasten
echo "[INFO] Configuring StorageClass for Kasten K10..."
kubectl annotate storageclass csi-hostpath-sc \
    k10.kasten.io/volume-snapshot-class=csi-hostpath-snapclass --overwrite

# Cleanup
cd "${PROJECT_ROOT}"
rm -rf csi-driver-host-path

echo "[INFO] CSI Driver installation complete!"
kubectl get storageclass
kubectl get volumesnapshotclass
