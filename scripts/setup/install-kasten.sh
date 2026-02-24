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
    --set global.persistence.storageClass=csi-hostpath-sc \
    --set prometheus.server.persistentVolume.storageClass=csi-hostpath-sc

# Wait for K10 resources to become ready using stable Helm labels and rollout status
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

TOTAL_TIMEOUT_SEC=${KASTEN_READY_TIMEOUT:-600}
INTERVAL_SEC=5
DIAG_INTERVAL_SEC=20
ELAPSED=0
LAST_DIAG=0

echo "[INFO] Monitoring K10 pod readiness (timeout: ${TOTAL_TIMEOUT_SEC}s)..."

while [ ${ELAPSED} -lt ${TOTAL_TIMEOUT_SEC} ]; do
  # Get counts
  TOTAL=$(kubectl -n "${K10_NAMESPACE}" get pods -l app.kubernetes.io/instance=k10 --no-headers 2>/dev/null | wc -l | tr -d ' ')
  READY_PODS=$(kubectl -n "${K10_NAMESPACE}" get pods -l app.kubernetes.io/instance=k10 \
                -o jsonpath='{range .items[*]}{.metadata.name} {range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null | \
              awk '{ok=1; for(i=2;i<=NF;i++) if($i!="true") ok=0; if(ok) r++} END{print r+0}')

  if [ -z "${TOTAL}" ] || [ "${TOTAL}" -eq 0 ]; then
    STATUS_MSG="No K10 pods yet"
  else
    STATUS_MSG="${READY_PODS}/${TOTAL} pods Ready"
  fi

  # Periodic diagnostics
  if [ $((ELAPSED - LAST_DIAG)) -ge ${DIAG_INTERVAL_SEC} ]; then
    echo "[INFO] ${STATUS_MSG} (t=${ELAPSED}s)"
    kubectl -n "${K10_NAMESPACE}" get pods -l app.kubernetes.io/instance=k10 -o wide 2>/dev/null || true
    NONREADY=$(kubectl -n "${K10_NAMESPACE}" get pods -l app.kubernetes.io/instance=k10 \
                -o jsonpath='{range .items[*]}{.metadata.name} {range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null | \
              awk '{ok=1; for(i=2;i<=NF;i++) if($i!="true") ok=0; if(!ok) print $1}')
    if [ -n "${NONREADY}" ]; then
      echo "[INFO] Diagnostics for non-ready pods:"
      for p in ${NONREADY}; do
        echo "[INFO] -> ${p}"
        kubectl -n "${K10_NAMESPACE}" get pod "${p}" -o jsonpath='Phase: {.status.phase}\nRestarts: {range .status.containerStatuses[*]}{.restartCount}{" "}{end}\nStates: {range .status.containerStatuses[*]}{.state}{"\n"}{end}\n' 2>/dev/null || true
        # If Pending, show PVCs briefly
        if kubectl -n "${K10_NAMESPACE}" get pod "${p}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q '^Pending$'; then
          echo "[INFO] PVCs in namespace ${K10_NAMESPACE}:"
          kubectl -n "${K10_NAMESPACE}" get pvc || true
        fi
      done
    fi
    LAST_DIAG=${ELAPSED}
  fi

  # Exit success when all pods Ready
  if [ -n "${TOTAL}" ] && [ "${TOTAL}" -gt 0 ] && [ "${READY_PODS}" = "${TOTAL}" ]; then
    echo "[INFO] All K10 pods are Ready (${TOTAL}/${TOTAL})."
    break
  fi

  sleep ${INTERVAL_SEC}
  ELAPSED=$((ELAPSED + INTERVAL_SEC))
done

if [ ${ELAPSED} -ge ${TOTAL_TIMEOUT_SEC} ]; then
  echo "[ERROR] K10 pods did not become Ready within ${TOTAL_TIMEOUT_SEC}s. Showing final diagnostics..." >&2
  kubectl -n "${K10_NAMESPACE}" get pods -o wide || true
  echo "[INFO] Recent K10 events:"
  kubectl -n "${K10_NAMESPACE}" get events --sort-by=.lastTimestamp | tail -50 || true
  exit 1
fi

echo "[INFO] Kasten K10 installation complete!"
echo ""
echo "Access dashboard: kubectl -n ${K10_NAMESPACE} port-forward svc/gateway 8080:8000"
echo "Get token: kubectl -n ${K10_NAMESPACE} create token k10-k10 --duration=24h"