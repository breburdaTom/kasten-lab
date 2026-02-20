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

th# Wait for K10 resources to become ready using stable Helm labels and rollout status
echo "[INFO] Waiting for K10 resources to become ready..."

# Ensure some pods are created before waiting (up to 10 tries with 10s interval)
TRIES=0
until [ "$TRIES" -ge 10 ]; do
  POD_COUNT=$(kubectl -n "${K10_NAMESPACE}" get pods -l app.kubernetes.io/instance=k10 --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$POD_COUNT" -gt 0 ]; then
    break
  fi
  TRIES=$((TRIES+1))
  echo "[INFO] Waiting for K10 pods to be created (attempt ${TRIES}/10)..."
  sleep 10
done

# Wait for all deployments to finish rolling out
DEPLOYMENTS=$(kubectl -n "${K10_NAMESPACE}" get deploy -l app.kubernetes.io/instance=k10 -o name 2>/dev/null || true)
if [ -n "$DEPLOYMENTS" ]; then
  echo "[INFO] Waiting for deployments to roll out..."
  for d in $DEPLOYMENTS; do
    echo "[INFO] -> $(basename "$d")"
    kubectl -n "${K10_NAMESPACE}" rollout status "$d" --timeout=10m
  done
else
  echo "[WARN] No K10 deployments found to wait on."
fi

# Also wait for pods with the instance label to be Ready (defensive)
set +e
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=k10 -n "${K10_NAMESPACE}" --timeout=10m
WAIT_RC=$?
set -e
if [ $WAIT_RC -ne 0 ]; then
  echo "[WARN] Not all K10 pods reported Ready within timeout; proceeding since deployments rolled out."
fi

# Annotate VolumeSnapshotClass for Kasten (in case CSI driver script didn't run)
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
    k10.kasten.io/is-snapshot-class=true --overwrite 2>/dev/null || true

echo "[INFO] Kasten K10 installation complete!"
echo ""
echo "Access dashboard: kubectl -n ${K10_NAMESPACE} port-forward svc/gateway 8080:8000"
echo "Get token: kubectl -n ${K10_NAMESPACE} create token k10-k10 --duration=24h"
