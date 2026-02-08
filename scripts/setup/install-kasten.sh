#!/usr/bin/env bash
# ==============================================================================
# Script: install-kasten.sh
# Description: Installs Kasten K10
# ==============================================================================

set -euo pipefail

K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"

echo "[INFO] Installing Kasten K10..."

# Add Helm repo
helm repo add kasten https://charts.kasten.io/ || true
helm repo update

# Create namespace
kubectl create namespace "${K10_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Install K10
helm upgrade --install k10 kasten/k10 \
    --namespace="${K10_NAMESPACE}" \
    --set eula.accept=true \
    --set eula.company=demo \
    --set eula.email=demo@example.com \
    --set auth.tokenAuth.enabled=true \
    --set global.persistence.storageClass=csi-hostpath-sc

# Wait for pods
echo "[INFO] Waiting for K10 pods..."
kubectl wait --for=condition=ready pod -l app=k10 -n "${K10_NAMESPACE}" --timeout=600s 2>/dev/null || \
sleep 60  # Fallback wait

# Annotate VolumeSnapshotClass for Kasten (in case CSI driver script didn't run)
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
    k10.kasten.io/is-snapshot-class=true --overwrite 2>/dev/null || true

echo "[INFO] Kasten K10 installation complete!"
echo ""
echo "Access dashboard: kubectl -n ${K10_NAMESPACE} port-forward svc/gateway 8080:8000"
echo "Get token: kubectl -n ${K10_NAMESPACE} create token k10-k10 --duration=24h"
