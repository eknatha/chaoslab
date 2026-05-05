#!/usr/bin/env bash
# scripts/cpu-stress.sh  —  Usage: cpu-stress.sh <namespace> <workers> <duration>
set -euo pipefail
NS="$1" WORKERS="$2" DUR="$3"
echo "[cpu-stress] ns=$NS workers=$WORKERS duration=${DUR}s"
kubectl delete pod chaos-cpu-stress -n "$NS" --ignore-not-found --grace-period=0 2>/dev/null || true
kubectl run chaos-cpu-stress \
  --image=polinux/stress --restart=Never -n "$NS" \
  --labels="chaos=true" \
  -- stress --cpu "$WORKERS" --timeout "${DUR}s"
echo "[cpu-stress] Pod deployed. Auto-terminates in ${DUR}s."
kubectl get pod chaos-cpu-stress -n "$NS"
