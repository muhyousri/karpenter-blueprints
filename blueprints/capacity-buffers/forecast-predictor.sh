#!/bin/bash
# Stand-in for an external predictive scaler.
#
# This script simulates a forecaster that knows, ahead of time, how many
# additional replicas a workload will need. Instead of scaling the real
# Deployment immediately, it patches a CapacityBuffer's replicas so Karpenter
# pre-provisions the capacity. When the forecast materializes (simulated here
# by a sleep), the real Deployment is scaled and lands on already-Ready nodes.
#
# Usage: ./forecast-predictor.sh <buffer-name> <forecast-replicas> <lead-time-seconds>

set -e

BUFFER_NAME="${1:-forecast-driven-buffer}"
FORECAST_REPLICAS="${2:-5}"
LEAD_TIME="${3:-90}"

echo "[predictor] Forecast: workload will need $FORECAST_REPLICAS additional replicas in ${LEAD_TIME}s"
echo "[predictor] Patching CapacityBuffer/$BUFFER_NAME to pre-provision capacity now..."

kubectl patch capacitybuffer "$BUFFER_NAME" --type='merge' -p="{\"spec\":{\"replicas\":$FORECAST_REPLICAS}}"

echo "[predictor] Buffer patched. Karpenter will provision nodes for the virtual buffer pods."
echo "[predictor] Waiting ${LEAD_TIME}s to simulate the forecast lead time..."
sleep "$LEAD_TIME"

echo "[predictor] Forecast window elapsed. Real demand should now be scaled by the workload owner's autoscaler."
