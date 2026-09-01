#!/usr/bin/env bash
# scripts/chaos.sh — inject or clean up a single fault.
#
#   chaos.sh inject  <fault>
#   chaos.sh cleanup <fault>
#
# Configuration arrives as environment variables, never as interpolated
# workflow expressions:
#   NS BLAST DURATION MAGNITUDE SEL EVICT
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

ACTION="${1:?inject or cleanup}"
FAULT="${2:?fault name}"

NS="${NS:-default}"
SEL="${SEL:-}"
DURATION="${DURATION:-60}"
MAGNITUDE="${MAGNITUDE:-0}"
BLAST="${BLAST:-30}"
EVICT="${EVICT:-true}"

CHAOS_LABEL="chaoslab.eknathalabs.com/chaos=true"

# ── Helpers ──────────────────────────────────────────────────────────────

# Pods to hit: a random sample capped at BLAST percent, minimum one.
target_pods() {
  local total max
  total="$(total_pods "$NS" "$SEL")"
  [ "$total" -gt 0 ] || die "No pods match '$SEL' in namespace '$NS'."
  max=$(( total * BLAST / 100 ))
  [ "$max" -lt 1 ] && max=1
  kubectl get pods -n "$NS" -l "$SEL" --no-headers -o custom-columns=':metadata.name' \
    | shuf | head -n "$max"
}

# Nodes hosting the targeted pods — used to bound node-level faults so a
# network fault cannot degrade the whole cluster.
target_nodes() {
  kubectl get pods -n "$NS" -l "$SEL" \
    -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | sort -u
}

node_affinity_block() {
  local nodes indent="        "
  nodes="$(target_nodes)"
  [ -n "$nodes" ] || die "Could not resolve the nodes hosting the target pods."
  printf '%saffinity:\n' "$indent"
  printf '%s  nodeAffinity:\n' "$indent"
  printf '%s    requiredDuringSchedulingIgnoredDuringExecution:\n' "$indent"
  printf '%s      nodeSelectorTerms:\n' "$indent"
  printf '%s        - matchExpressions:\n' "$indent"
  printf '%s            - key: kubernetes.io/hostname\n' "$indent"
  printf '%s              operator: In\n' "$indent"
  printf '%s              values:\n' "$indent"
  printf "%s                - %s\n" "$indent" $nodes
  printf '%s            - key: node-role.kubernetes.io/control-plane\n' "$indent"
  printf '%s              operator: DoesNotExist\n' "$indent"
}

# A netem DaemonSet that always removes its own qdisc, even on SIGTERM.
apply_netem() {
  local name="$1" netem_args="$2"
  local iface_cmd
  iface_cmd="$(default_iface_cmd)"

  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    chaoslab.eknathalabs.com/chaos: "true"
spec:
  selector:
    matchLabels: { app: ${name} }
  template:
    metadata:
      labels:
        app: ${name}
        chaoslab.eknathalabs.com/chaos: "true"
    spec:
      hostNetwork: true
      terminationGracePeriodSeconds: 30
$(node_affinity_block)
      containers:
        - name: netem
          image: nicolaka/netshoot:latest
          securityContext:
            privileged: true
            capabilities: { add: ["NET_ADMIN"] }
          command: [sh, -c]
          args:
            - |
              IFACE=\$(${iface_cmd})
              [ -z "\$IFACE" ] && IFACE=eth0
              echo "netem on \$IFACE: ${netem_args}"
              cleanup() { tc qdisc del dev "\$IFACE" root 2>/dev/null || true; echo "netem removed"; exit 0; }
              trap cleanup EXIT TERM INT
              tc qdisc replace dev "\$IFACE" root netem ${netem_args}
              sleep ${DURATION} &
              wait \$!
              cleanup
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
YAML
  kubectl rollout status "daemonset/${name}" -n "$NS" --timeout=90s || true
}

# ── Injection ────────────────────────────────────────────────────────────
inject() {
  case "$FAULT" in

  pod-kill)
    local pods
    pods="$(target_pods)"
    log "deleting $(echo "$pods" | wc -l | tr -d ' ') pod(s), evict=$EVICT"
    for p in $pods; do
      if [ "$EVICT" = "true" ]; then
        # Eviction API honours PodDisruptionBudgets. A blocked eviction is a
        # passing result, not an error: the PDB did its job.
        if kubectl create -f - <<YAML >/dev/null 2>&1
apiVersion: policy/v1
kind: Eviction
metadata: { name: "${p}", namespace: "${NS}" }
YAML
        then log "evicted $p"
        else warn "eviction of $p refused — a PodDisruptionBudget held it back"
        fi
      else
        kubectl delete pod "$p" -n "$NS" --wait=false
        log "deleted $p (graceful, preStop hooks run)"
      fi
    done
    ;;

  container-kill)
    # Kills the process inside the container without deleting the pod, so
    # this exercises restartPolicy rather than rescheduling.
    local pods
    pods="$(target_pods)"
    for p in $pods; do
      kubectl exec -n "$NS" "$p" -- sh -c 'kill 1' 2>/dev/null \
        && log "killed PID 1 in $p" \
        || warn "could not exec into $p — the image may have no shell"
    done
    ;;

  cpu-stress)
    local workers="${MAGNITUDE:-4}" i=0
    for p in $(target_pods); do
      i=$((i + 1))
      kubectl run "chaos-cpu-$i" -n "$NS" \
        --image=polinux/stress --restart=Never \
        --labels="chaoslab.eknathalabs.com/chaos=true" \
        --overrides='{"spec":{"nodeName":"'"$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.spec.nodeName}')"'"}}' \
        -- stress --cpu "$workers" --timeout "${DURATION}s" >/dev/null
      log "cpu stress pod chaos-cpu-$i placed alongside $p ($workers workers)"
    done
    ;;

  memory-stress)
    # Requests more memory than the limit allows, so the kernel OOM-kills it.
    local mb="${MAGNITUDE:-512}" i=0
    for p in $(target_pods); do
      i=$((i + 1))
      kubectl run "chaos-mem-$i" -n "$NS" \
        --image=polinux/stress --restart=Never \
        --labels="chaoslab.eknathalabs.com/chaos=true" \
        --limits="memory=$((mb / 2))Mi" \
        --overrides='{"spec":{"nodeName":"'"$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.spec.nodeName}')"'"}}' \
        -- stress --vm 1 --vm-bytes "${mb}M" --vm-hang 0 --timeout "${DURATION}s" >/dev/null
      log "memory stress pod chaos-mem-$i allocating ${mb}Mi against a $((mb / 2))Mi limit"
    done
    ;;

  disk-fill)
    local mb="${MAGNITUDE:-1024}"
    kubectl run chaos-disk -n "$NS" \
      --image=busybox:1.36 --restart=Never \
      --labels="chaoslab.eknathalabs.com/chaos=true" \
      -- sh -c "dd if=/dev/zero of=/tmp/chaos-fill bs=1M count=${mb}; sleep ${DURATION}" >/dev/null
    log "filling ${mb}Mi of ephemeral storage for ${DURATION}s"
    ;;

  net-delay)
    apply_netem chaos-net-delay "delay ${MAGNITUDE:-500}ms 20ms distribution normal"
    ;;

  net-loss)
    apply_netem chaos-net-loss "loss ${MAGNITUDE:-15}%"
    ;;

  dns-blackhole)
    # Blocks the targeted pods from reaching cluster DNS with a NetworkPolicy.
    # Precise, namespaced and instantly reversible — no privileged container.
    local key="${SEL%%=*}" val="${SEL#*=}"
    kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chaos-dns-blackhole
  namespace: ${NS}
  labels:
    chaoslab.eknathalabs.com/chaos: "true"
spec:
  podSelector:
    matchLabels: { ${key}: "${val}" }
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: { cidr: 0.0.0.0/0 }
      ports:
        - { protocol: TCP, port: 80 }
        - { protocol: TCP, port: 443 }
YAML
    log "cluster DNS blocked for pods matching $SEL (egress on 53 removed)"
    warn "requires a CNI that enforces NetworkPolicy — Calico, Cilium, or similar"
    ;;

  node-drain)
    local node
    node="$(target_nodes | head -1)"
    [ -n "$node" ] || die "No worker node hosts the target pods."
    kubectl get node "$node" -o jsonpath='{.metadata.labels}' | grep -q 'control-plane' \
      && die "Refusing to drain control-plane node $node."
    echo "$node" > /tmp/chaos-drained-node
    kubectl cordon "$node"
    log "cordoned $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
      --timeout=120s --skip-wait-for-delete-timeout=30s \
      || warn "drain did not complete — a PodDisruptionBudget is holding pods on the node"
    ;;

  zone-outage)
    # Cordons every node in one topology zone and evicts the target pods
    # from it, simulating an availability-zone failure.
    local zone nodes
    zone="$(kubectl get nodes -o 'jsonpath={.items[0].metadata.labels.topology\.kubernetes\.io/zone}')"
    [ -n "$zone" ] || die "Nodes carry no topology.kubernetes.io/zone label."
    nodes="$(kubectl get nodes -l "topology.kubernetes.io/zone=$zone,!node-role.kubernetes.io/control-plane" \
      --no-headers -o custom-columns=':metadata.name')"
    echo "$nodes" > /tmp/chaos-drained-node
    log "taking out zone $zone: $(echo "$nodes" | tr '\n' ' ')"
    for n in $nodes; do kubectl cordon "$n"; done
    for n in $nodes; do
      kubectl delete pods -n "$NS" -l "$SEL" \
        --field-selector "spec.nodeName=$n" --wait=false 2>/dev/null || true
    done
    ;;

  *) die "Unknown fault '$FAULT'." ;;
  esac
}

# ── Cleanup ──────────────────────────────────────────────────────────────
# Runs unconditionally after every live experiment, including failures,
# timeouts and cancellations.
cleanup() {
  log "cleanup: $FAULT in $NS"

  kubectl delete pods,daemonsets,networkpolicies -n "$NS" \
    -l "$CHAOS_LABEL" --ignore-not-found --grace-period=0 --force 2>/dev/null || true

  # A netem qdisc outlives its pod if the node was under pressure when the
  # DaemonSet was removed. This scrub guarantees the node is left clean.
  case "$FAULT" in
    net-delay|net-loss) scrub_netem ;;
  esac

  if [ -f /tmp/chaos-drained-node ]; then
    while read -r n; do
      [ -n "$n" ] && kubectl uncordon "$n" 2>/dev/null && log "uncordoned $n"
    done < /tmp/chaos-drained-node
    rm -f /tmp/chaos-drained-node
  fi
}

scrub_netem() {
  local iface_cmd
  iface_cmd="$(default_iface_cmd)"
  log "scrubbing leftover netem qdiscs from every node"
  kubectl apply -f - <<YAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: chaos-netem-scrub
  namespace: ${NS}
  labels:
    chaoslab.eknathalabs.com/chaos: "true"
spec:
  ttlSecondsAfterFinished: 60
  template:
    metadata:
      labels:
        chaoslab.eknathalabs.com/chaos: "true"
    spec:
      hostNetwork: true
      restartPolicy: Never
      containers:
        - name: scrub
          image: nicolaka/netshoot:latest
          securityContext:
            privileged: true
            capabilities: { add: ["NET_ADMIN"] }
          command: [sh, -c]
          args:
            - |
              IFACE=\$(${iface_cmd}); [ -z "\$IFACE" ] && IFACE=eth0
              tc qdisc del dev "\$IFACE" root 2>/dev/null || true
              echo "qdisc cleared on \$IFACE"
YAML
  kubectl wait --for=condition=complete job/chaos-netem-scrub -n "$NS" --timeout=60s 2>/dev/null || true
  kubectl delete job chaos-netem-scrub -n "$NS" --ignore-not-found 2>/dev/null || true
}

case "$ACTION" in
  inject)  inject ;;
  cleanup) cleanup ;;
  *) die "Unknown action '$ACTION'." ;;
esac
