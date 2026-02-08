#!/usr/bin/env bash
# ==============================================================================
# Script: install-snapshot-controller.sh
# Description: Installs CSI Snapshot Controller and CRDs
# ==============================================================================

set -euo pipefail

SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v7.0.2}"

echo "[INFO] Installing Snapshot Controller (${SNAPSHOTTER_VERSION})..."

# Install CRDs
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"

# Install Snapshot Controller
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"

# Wait for controller
echo "[INFO] Waiting for Snapshot Controller..."
kubectl wait --for=condition=available deployment/snapshot-controller -n kube-system --timeout=300s

echo "[INFO] Snapshot Controller installation complete!"
