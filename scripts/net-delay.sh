#!/usr/bin/env bash
# scripts/net-delay.sh  —  Usage: net-delay.sh <namespace> <delay_ms> <duration>
set -euo pipefail
NS="$1" DELAY="$2" DUR="$3"
echo "[net-delay] ns=$NS delay=${DELAY}ms duration=${DUR}s"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chaos-net-delay
  namespace: ${NS}
  labels: { chaos: "true" }
spec:
  selector:
    matchLabels: { app: chaos-net-delay }
  template:
    metadata:
      labels: { app: chaos-net-delay, chaos: "true" }
    spec:
      hostNetwork: true
      tolerations:
        - operator: Exists
      containers:
        - name: netem
          image: nicolaka/netshoot
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN"]
          command: [sh, -c]
          args:
            - |
              tc qdisc add dev eth0 root netem delay ${DELAY}ms 20ms distribution normal \
                || tc qdisc change dev eth0 root netem delay ${DELAY}ms 20ms distribution normal
              sleep ${DUR}
              tc qdisc del dev eth0 root 2>/dev/null || true
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 100m, memory: 128Mi }
EOF
echo "[net-delay] DaemonSet deployed. ${DELAY}ms latency injected for ${DUR}s."
