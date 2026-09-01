#!/usr/bin/env bash
# scripts/postmortem.sh — turn a finished live experiment into the incident
# report you would have written if the failure had happened on its own.
#
# Reads the environment the chaos workflow has already populated, plus the
# timeline written by note() during the run. Emits GitHub-flavoured markdown
# on stdout. Deliberately mirrors the browser report so a simulator run and a
# live run produce the same document.
set -uo pipefail

FAULT="${FAULT:-unknown}"
NS="${NS:-default}"
SEL="${SEL:-}"
DURATION="${DURATION:-0}"
BLAST="${BLAST:-0}"
MAGNITUDE="${MAGNITUDE:-0}"
DRY="${DRY:-false}"
SLO="${SLO:-}"
BASELINE="${BASELINE:-}"
BREACH="${BREACH:-}"
READY_BEFORE="${READY_BEFORE:-?}"
READY_AFTER="${READY_AFTER:-?}"
RECOVERED="${RECOVERED:-}"
VERDICT="${VERDICT:-unknown}"
ABORTED="${ABORTED:-}"
FIRST_BREACH_T="${FIRST_BREACH_T:-}"
RECOVERY_T="${RECOVERY_T:-}"
CHAOS_RESULT="${CHAOS_RESULT:-}"
LOW_READY="${LOW_READY:-}"
TIMELINE="${CHAOS_TIMELINE:-/tmp/chaos-timeline.txt}"
RUN_URL="${RUN_URL:-}"

label_of() {
  case "$1" in
    pod-kill)       echo "Pod kill" ;;
    container-kill) echo "Container kill" ;;
    cpu-stress)     echo "CPU stress" ;;
    memory-stress)  echo "Memory pressure" ;;
    disk-fill)      echo "Disk fill" ;;
    net-delay)      echo "Network delay" ;;
    net-loss)       echo "Packet loss" ;;
    dns-blackhole)  echo "DNS blackhole" ;;
    node-drain)     echo "Node drain" ;;
    zone-outage)    echo "Zone outage" ;;
    *)              echo "$1" ;;
  esac
}

blast_applies() {
  case "$1" in
    pod-kill|container-kill|cpu-stress|memory-stress) return 0 ;;
    *) return 1 ;;
  esac
}

slo_field() { printf '%s' "$SLO" | tr ';' '\n' | sed -n "s/^${1}=//p" | head -1; }

# Markdown table cells are pipe-delimited, so anything interpolated into one
# has to have its pipes escaped first.
cell() { printf '%s' "${1:-}" | sed 's/|/\\|/g'; }

# Pull a single metric back out of an slo_evaluate result line.
metric() { printf '%s' "${1:-}" | sed -n "s/.*${2}=\([^ ]*\).*/\1/p" | head -1; }

fmt_time() {
  local s="${1:-}"
  [ -z "$s" ] && { echo "not reached"; return; }
  if [ "$s" -lt 60 ]; then echo "${s}s"; else echo "$((s / 60))m $((s % 60))s"; fi
}

LABEL="$(label_of "$FAULT")"
P95_MAX="$(slo_field p95_ms)"
ERR_MAX="$(slo_field err_pct)"
MIN_READY="$(slo_field min_ready)"

if [ "$DRY" = "true" ]; then
  cat <<MD
# Preview: ${LABEL} on ${NS}

This was a dry run. Nothing was injected, so there is no incident to report.

| | |
|---|---|
| Fault | \`${FAULT}\` |
| Namespace | \`${NS}\` |
| Selector | \`${SEL}\` |
| Would affect | up to ${BLAST}% of matching pods |

Re-run with \`dry_run: false\` to produce a real report.
MD
  exit 0
fi

echo "# Incident report: ${LABEL} on ${NS}"
echo
echo "**Date** $(date -u '+%Y-%m-%d %H:%M') UTC  "
echo "**Experiment** \`${FAULT}\` · ${DURATION}s · blast radius ${BLAST}%$([ "$MAGNITUDE" != "0" ] && echo " · magnitude ${MAGNITUDE}")  "
echo "**Target** \`${SEL}\` in \`${NS}\`  "
echo "**Source** live cluster, dispatched through GitHub Actions  "
case "$VERDICT" in
  pass)  echo "**Outcome** the hypothesis held" ;;
  abort) echo "**Outcome** the hypothesis broke, and the run was stopped early" ;;
  *)     echo "**Outcome** the hypothesis broke" ;;
esac
echo

# ── What happened ────────────────────────────────────────────────────────
echo "## What happened"
echo
if [ "$VERDICT" = "pass" ]; then
  echo "A ${LABEL} fault was injected against \`${SEL}\` for ${DURATION} seconds. The workload stayed inside its stated steady state throughout and returned to full strength afterwards. Ready pods went from ${READY_BEFORE} to ${READY_AFTER}."
elif [ -z "$BREACH" ]; then
  echo "A ${LABEL} fault was injected against \`${SEL}\` for ${DURATION} seconds. Steady state was healthy beforehand${BASELINE:+ at ${BASELINE}}, and the stated thresholds were never crossed while the fault was active."
  echo
  echo "The experiment failed on recovery rather than on impact: once the fault was removed the workload did not return to its original ready count within the recovery window. Ready pods went from ${READY_BEFORE} to ${READY_AFTER}. A fault that is survivable but not self-healing still needs a human, which makes it an availability risk even though every threshold held."
else
  echo "A ${LABEL} fault was injected against \`${SEL}\`. Steady state was measured first and was healthy${BASELINE:+ at $(cell "$BASELINE")}. Within $(fmt_time "$FIRST_BREACH_T") of injection the workload was outside its stated bounds: $(cell "$BREACH")."
  echo
  if [ "$ABORTED" = "true" ]; then
    printf '%s' "The abort condition fired, the fault was removed and the namespace was rolled back rather than riding out the full duration."
  else
    printf '%s' "The experiment ran to completion."
  fi
  if [ "$RECOVERED" = "true" ]; then
    echo " The workload was back to full strength${RECOVERY_T:+ $(fmt_time "$RECOVERY_T") after it first fell below}."
  else
    echo " The workload had not returned to full strength when the run ended."
  fi
fi
echo

# ── Impact ───────────────────────────────────────────────────────────────
echo "## Impact"
echo
BASE_P95="$(metric "$BASELINE" p95)"
CHAOS_P95="$(metric "${CHAOS_RESULT:-$BREACH}" p95)"
BASE_ERR="$(printf '%s' "$BASELINE" | sed -n 's/.*(\([0-9]*\)%).*/\1/p')"
CHAOS_ERR="$(printf '%s' "${CHAOS_RESULT:-$BREACH}" | sed -n 's/.*(\([0-9]*\)%).*/\1/p')"

echo "| | Before | During fault | Threshold |"
echo "|---|---|---|---|"
CHAOS_READY="${LOW_READY:-$(metric "${CHAOS_RESULT:-$BREACH}" ready)}"
echo "| Ready pods | ${READY_BEFORE} | ${CHAOS_READY:-not measured} | $([ -n "$MIN_READY" ] && echo "at least ${MIN_READY}" || echo "not set") |"
echo "| p95 latency | ${BASE_P95:-not measured} | ${CHAOS_P95:-not measured} | $([ -n "$P95_MAX" ] && echo "${P95_MAX}ms" || echo "not set") |"
echo "| Error rate | ${BASE_ERR:-0}% | ${CHAOS_ERR:-0}% | $([ -n "$ERR_MAX" ] && echo "${ERR_MAX}%" || echo "not set") |"
echo
if [ -n "$FIRST_BREACH_T" ]; then
  echo "- **Time to detection** $(fmt_time "$FIRST_BREACH_T") after injection"
else
  echo "- **Time to detection** the hypothesis was never breached"
fi
if [ "$RECOVERED" != "true" ]; then
  echo "- **Time to recovery** it had not recovered when the run ended"
elif [ -n "$RECOVERY_T" ] && [ "$RECOVERY_T" -gt 0 ]; then
  echo "- **Time to recovery** $(fmt_time "$RECOVERY_T") back to the original ready count"
else
  echo "- **Time to recovery** the workload never fell below full strength"
fi
if blast_applies "$FAULT"; then
  echo "- **Blast radius** ${BLAST}% of matching pods"
else
  echo "- **Scope** node level — this fault affects whole nodes, so the pod blast radius does not apply"
fi
echo

# ── Timeline ─────────────────────────────────────────────────────────────
if [ -s "$TIMELINE" ]; then
  echo "## Timeline"
  echo
  echo "| Offset | Event |"
  echo "|---|---|"
  # Fields are t|level|msg; pipes inside a message are escaped for the table.
  head -40 "$TIMELINE" | while IFS='|' read -r t _level msg; do
    [ -z "${t:-}" ] && continue
    printf '| t+%ss | %s |\n' "$t" "$(printf '%s' "$msg" | sed 's/|/\\|/g')"
  done
  echo
fi

# ── Hypothesis ───────────────────────────────────────────────────────────
echo "## Hypothesis"
echo
echo '```'
echo "${SLO:-none set — the run was graded on recovery alone}"
echo '```'
echo
if [ "$VERDICT" = "pass" ]; then
  echo "The hypothesis held for the whole experiment."
elif [ -n "$BREACH" ]; then
  echo "The hypothesis was broken on: $(cell "$BREACH")."
else
  echo "No threshold was crossed. The run failed because the workload did not recover on its own."
fi
echo

# ── Contributing factors and action items ────────────────────────────────
FACTORS=""
add_factor() { case " $FACTORS " in *" $1 "*) ;; *) FACTORS="$FACTORS $1" ;; esac; }

PDB_COUNT="$(kubectl get pdb -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
HPA_COUNT="$(kubectl get hpa -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
LIMITS="$(kubectl get pods -n "$NS" -l "$SEL" -o 'jsonpath={.items[*].spec.containers[*].resources.limits}' 2>/dev/null)"
READY_PROBE="$(kubectl get pods -n "$NS" -l "$SEL" -o 'jsonpath={.items[*].spec.containers[*].readinessProbe}' 2>/dev/null)"
SPREAD="$(kubectl get pods -n "$NS" -l "$SEL" -o 'jsonpath={.items[*].spec.topologySpreadConstraints}' 2>/dev/null)"

if [ "$VERDICT" != "pass" ]; then
  [ "$RECOVERED" = "false" ] && add_factor recovery
  case "$FAULT" in
    pod-kill|node-drain|zone-outage) [ "${PDB_COUNT:-0}" -eq 0 ] && add_factor pdb ;;
  esac
  case "$FAULT" in
    zone-outage|node-drain) [ -z "$SPREAD" ] && add_factor spread ;;
  esac
  case "$FAULT" in
    cpu-stress|memory-stress) [ -z "$LIMITS" ] && add_factor limits ;;
  esac
  case "$FAULT" in
    cpu-stress|zone-outage) [ "${HPA_COUNT:-0}" -eq 0 ] && add_factor hpa ;;
  esac
  case "$FAULT" in
    net-delay|net-loss) add_factor timeout ;;
    dns-blackhole)      add_factor dns ;;
  esac
  [ -z "$READY_PROBE" ] && add_factor readiness
fi

factor_title() {
  case "$1" in
    recovery)  echo "Recovery was not automatic" ;;
    pdb)       echo "No PodDisruptionBudget in ${NS}" ;;
    spread)    echo "Replicas are not spread across failure domains" ;;
    limits)    echo "No resource limits on the target containers" ;;
    hpa)       echo "No autoscaler to absorb the load" ;;
    readiness) echo "No readiness probe gating traffic" ;;
    timeout)   echo "Client timeouts are longer than the injected delay" ;;
    dns)       echo "No DNS resilience" ;;
  esac
}
factor_detail() {
  case "$1" in
    recovery)  echo "The fault was removed but the workload did not get back to ${READY_BEFORE} ready pods on its own. Check for pods stuck in CrashLoopBackOff, a scheduler with nowhere to place them, or a probe that never passes again after a restart." ;;
    pdb)       echo "Evictions had nothing to hold them back, so the disruption took as many pods as it wanted." ;;
    spread)    echo "The scheduler was free to place every replica in one zone, so losing that zone lost all of them." ;;
    limits)    echo "Resource pressure was not contained to the workload, so the kubelet began evicting by QoS class across the node." ;;
    hpa)       echo "Capacity was fixed, so the surviving pods carried the whole load until the fault was removed." ;;
    readiness) echo "Requests reached pods before they could serve them, turning every restart into an error spike." ;;
    timeout)   echo "Slow responses held connections open instead of failing fast, so latency propagated upstream rather than being shed." ;;
    dns)       echo "Losing cluster DNS translated directly into request failures. Nothing cached, and connections were not reused across lookups." ;;
  esac
}
factor_action() {
  case "$1" in
    recovery)  echo "Find out why the workload did not return to ${READY_BEFORE} ready pods" ;;
    pdb)       echo "Add a PodDisruptionBudget to the workload" ;;
    spread)    echo "Spread replicas across zones with a topology spread constraint" ;;
    limits)    echo "Set CPU and memory limits on the container" ;;
    hpa)       echo "Add a HorizontalPodAutoscaler" ;;
    readiness) echo "Add a readiness probe so traffic waits for the pod" ;;
    timeout)   echo "Set a request timeout below the latency SLO" ;;
    dns)       echo "Tune DNS options and enable connection keep-alive" ;;
  esac
}
factor_fix() {
  case "$1" in
    recovery)
      printf '%s\n' "kubectl get pods -n ${NS} -l ${SEL}" \
                    "kubectl describe pod <stuck-pod> -n ${NS}" \
                    "kubectl get events -n ${NS} --sort-by=.lastTimestamp" ;;
    pdb)
      printf '%s\n' "apiVersion: policy/v1" "kind: PodDisruptionBudget" "metadata:" \
                    "  name: <workload>" "  namespace: ${NS}" "spec:" \
                    "  minAvailable: ${MIN_READY:-2}" "  selector:" "    matchLabels:" \
                    "      # the labels behind ${SEL}" ;;
    spread)
      printf '%s\n' "topologySpreadConstraints:" "  - maxSkew: 1" \
                    "    topologyKey: topology.kubernetes.io/zone" \
                    "    whenUnsatisfiable: DoNotSchedule" "    labelSelector:" \
                    "      matchLabels:" "        # the labels behind ${SEL}" ;;
    limits)
      printf '%s\n' "resources:" "  requests:" "    cpu: 100m" "    memory: 128Mi" \
                    "  limits:" "    cpu: 500m" "    memory: 512Mi" ;;
    hpa)
      printf '%s\n' "apiVersion: autoscaling/v2" "kind: HorizontalPodAutoscaler" "spec:" \
                    "  minReplicas: ${READY_BEFORE}" "  maxReplicas: $((${READY_BEFORE:-2} * 3))" \
                    "  metrics:" "    - type: Resource" \
                    "      resource:" "        name: cpu" \
                    "        target: { type: Utilization, averageUtilization: 70 }" ;;
    readiness)
      printf '%s\n' "readinessProbe:" "  httpGet: { path: /readyz, port: 8080 }" \
                    "  initialDelaySeconds: 5" "  periodSeconds: 5" ;;
    timeout)
      printf '%s\n' "# set a request timeout below your SLO, and a circuit breaker above it" \
                    "# Envoy, an Istio DestinationRule, or the client library equivalent" ;;
    dns)
      printf '%s\n' "dnsConfig:" "  options:" '    - { name: ndots, value: "2" }' \
                    '    - { name: timeout, value: "2" }' '    - { name: attempts, value: "2" }' \
                    "# and keep-alive on the client so a working connection survives a DNS outage" ;;
  esac
}

if [ -n "$FACTORS" ]; then
  echo "## Contributing factors"
  echo
  i=1
  for f in $FACTORS; do
    echo "${i}. **$(factor_title "$f").** $(factor_detail "$f")"
    i=$((i + 1))
  done
  echo
fi

# ── What went well ───────────────────────────────────────────────────────
echo "## What went well"
echo
GOOD=0
if [ -n "$READY_PROBE" ]; then
  echo "- The readiness probe kept traffic off pods that were not able to serve, so restarts did not become error spikes."; GOOD=1
fi
if [ "${PDB_COUNT:-0}" -gt 0 ]; then
  echo "- A PodDisruptionBudget was in place and enforced during the disruption."; GOOD=1
fi
if [ "${HPA_COUNT:-0}" -gt 0 ]; then
  echo "- An autoscaler was available to add capacity while the fault was active."; GOOD=1
fi
if [ "$RECOVERED" = "true" ]; then
  echo "- Recovery was automatic and needed no human involvement."; GOOD=1
fi
if [ "$ABORTED" = "true" ]; then
  echo "- The abort condition fired and cut the experiment short, which is the guardrail working as intended."; GOOD=1
fi
[ "$GOOD" -eq 0 ] && echo "- The experiment was contained: the fault was removed cleanly and the namespace was rolled back."
echo

# ── Action items ─────────────────────────────────────────────────────────
if [ -n "$FACTORS" ]; then
  echo "## Action items"
  echo
  for f in $FACTORS; do
    echo "- [ ] $(factor_action "$f")"
    echo
    echo '  ```yaml'
    factor_fix "$f" | sed 's/^/  /'
    echo '  ```'
    echo
  done
fi

# ── Next experiment ──────────────────────────────────────────────────────
echo "## Next experiment"
echo
if [ "$VERDICT" = "pass" ]; then
  if blast_applies "$FAULT" && [ "$BLAST" -lt 100 ]; then
    NEXT=$((BLAST * 2)); [ "$NEXT" -gt 100 ] && NEXT=100
    echo "Repeat \`${FAULT}\` at a blast radius of ${NEXT}% to find the edge."
  else
    echo "Combine \`${FAULT}\` with a second fault, or extend the duration past ${DURATION}s, to see what breaks under sustained pressure."
  fi
else
  case " $FACTORS " in
    *" pdb "*)    echo "Add the PodDisruptionBudget, then run the identical \`${FAULT}\` experiment again. The eviction should be refused rather than granted." ;;
    *" spread "*) echo "Add the topology spread constraint and re-run \`${FAULT}\`. The remaining zones should absorb it." ;;
    *" limits "*) echo "Set the resource limits and re-run \`${FAULT}\` at the same magnitude, then compare the ready pod floor." ;;
    *)            echo "Fix the top action item, then re-run \`${FAULT}\` unchanged so the before and after are comparable." ;;
  esac
fi
echo
echo "---"
echo
if [ -n "$RUN_URL" ]; then
  echo "_Generated by [ChaosLab](https://chaoslab.eknathalabs.com) from [this run](${RUN_URL})._"
else
  echo "_Generated by [ChaosLab](https://chaoslab.eknathalabs.com)._"
fi
