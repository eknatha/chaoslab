#!/usr/bin/env bash
# scripts/rollback.sh  —  Usage: rollback.sh <namespace>
set -euo pipefail
NS="${1:-default}"
echo "=== CHAOSLAB EMERGENCY ROLLBACK | ns=$NS ==="

echo "1/5 Remove chaos-cpu-stress pod..."
kubectl delete pod chaos-cpu-stress -n "$NS" --ignore-not-found --grace-period=0 2>/dev/null && echo "  done" || echo "  not found"

echo "2/5 Remove chaos-net-delay DaemonSet..."
kubectl delete daemonset chaos-net-delay -n "$NS" --ignore-not-found 2>/dev/null && echo "  done" || echo "  not found"

echo "3/5 Remove pods labelled chaos=true..."
kubectl delete pods -n "$NS" -l chaos=true --ignore-not-found --grace-period=0 2>/dev/null && echo "  done" || echo "  none found"

echo "4/5 Uncordon any cordoned nodes..."
CORDONED=$(kubectl get nodes --field-selector=spec.unschedulable=true --no-headers -o name 2>/dev/null || true)
if [ -z "$CORDONED" ]; then echo "  no cordoned nodes"; else echo "$CORDONED" | xargs -I{} kubectl uncordon {} && echo "  done"; fi

echo "5/5 Rolling restart all deployments in $NS..."
kubectl rollout restart deployment -n "$NS" 2>/dev/null && echo "  done" || echo "  no deployments"
kubectl rollout status  deployment -n "$NS" --timeout=90s 2>/dev/null || true

echo ""
echo "=== ROLLBACK COMPLETE ==="
kubectl get pods -n "$NS"
kubectl get nodes
