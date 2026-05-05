#!/usr/bin/env bash
# scripts/pod-kill.sh  —  Usage: pod-kill.sh <namespace> <selector> <max_kill>
set -euo pipefail
NS="$1" SEL="$2" MAX="$3"
echo "[pod-kill] ns=$NS sel=$SEL max=$MAX"
PODS=$(kubectl get pods -n "$NS" -l "$SEL" --no-headers -o name | head -n "$MAX")
[ -z "$PODS" ] && { echo "No pods found."; exit 1; }
echo "[pod-kill] Deleting:"; echo "$PODS"
echo "$PODS" | xargs -I{} kubectl delete {} -n "$NS" --grace-period=0 --force 2>/dev/null || true
echo "[pod-kill] Done. ReplicaSet will reschedule automatically."
