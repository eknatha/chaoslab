#!/usr/bin/env bash
# scripts/lib.sh — shared guards, probes and SLO evaluation for ChaosLab.
# Sourced by chaos.sh and rollback.sh. Never interpolates workflow inputs
# directly into shell; every value arrives as an environment variable.

set -euo pipefail

# ── Namespaces that no experiment may ever target ────────────────────────
PROTECTED_NAMESPACES_DEFAULT="kube-system kube-public kube-node-lease gatekeeper-system cert-manager istio-system"

# ── Logging ──────────────────────────────────────────────────────────────
log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# note <offset_seconds> <level> <message>
# Appends one line to the run timeline, which postmortem.sh turns into the
# incident report. Pipes are stripped so the markdown table cannot be broken
# by a pod name or an error string.
note() {
  local t="${1:-0}" level="${2:-info}"
  shift 2 || true
  printf '%s|%s|%s\n' "$t" "$level" "$(printf '%s' "$*" | tr '|' '/' | tr -d '\n')" \
    >> "${CHAOS_TIMELINE:-/tmp/chaos-timeline.txt}"
}
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }
warn() { printf '::warning::%s\n' "$*" >&2; }

# ── Input validation ─────────────────────────────────────────────────────
# Kubernetes names: RFC 1123 label. Rejects spaces, semicolons, backticks,
# command substitution — the whole shell-injection surface.
valid_k8s_name() {
  printf '%s' "${1:-}" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
}

# Label selectors: letters, digits, and the selector grammar only.
valid_selector() {
  [ "${#1}" -le 253 ] || return 1
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_./=,!() -]*$'
}

valid_int() {
  printf '%s' "${1:-}" | grep -Eq '^[0-9]+$' || return 1
  [ "$1" -ge "${2:-0}" ] && [ "$1" -le "${3:-100000}" ]
}

# Trims surrounding whitespace so "kube-system " cannot slip past the guard.
trim() { printf '%s' "${1:-}" | tr -d '[:space:]'; }

guard_namespace() {
  local ns protected
  ns="$(trim "${1:-}")"
  protected="${PROTECTED_NAMESPACES:-$PROTECTED_NAMESPACES_DEFAULT}"

  [ -n "$ns" ] || die "Namespace is required."
  valid_k8s_name "$ns" || die "Namespace '$ns' is not a valid Kubernetes name."

  local p
  for p in $protected; do
    [ "$ns" = "$p" ] && die "Namespace '$ns' is protected and can never be targeted."
  done

  # Optional allowlist. Set CHAOS_ALLOWED_NAMESPACES as a repository variable
  # to restrict experiments to named namespaces only.
  if [ -n "${CHAOS_ALLOWED_NAMESPACES:-}" ]; then
    local ok=0 a
    for a in $CHAOS_ALLOWED_NAMESPACES; do
      [ "$ns" = "$a" ] && ok=1
    done
    [ "$ok" -eq 1 ] || die "Namespace '$ns' is not in CHAOS_ALLOWED_NAMESPACES."
  fi
  printf '%s' "$ns"
}

guard_selector() {
  local sel="${1:-}"
  [ -n "$sel" ] || die "Label selector is required (for example app=frontend)."
  valid_selector "$sel" || die "Selector '$sel' contains characters that are not allowed."
  printf '%s' "$sel"
}

# Node interface detection — never assume eth0. EKS uses ens5, GKE uses ens4.
default_iface_cmd() {
  printf '%s' "ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1"
}

# ── Target inspection ────────────────────────────────────────────────────
ready_pods() {
  kubectl get pods -n "$1" -l "$2" \
    -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$' || true
}

total_pods() {
  kubectl get pods -n "$1" -l "$2" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Prints a resilience posture summary for the targeted workload so the run
# log explains *why* a fault did or did not hurt.
preflight_posture() {
  local ns="$1" sel="$2"
  echo "── target posture ──────────────────────────────"
  kubectl get pods -n "$ns" -l "$sel" -o wide 2>/dev/null || true

  local pdbs
  pdbs="$(kubectl get pdb -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$pdbs" -eq 0 ]; then
    echo "PodDisruptionBudget : none in $ns — evictions will not be held back"
  else
    kubectl get pdb -n "$ns" 2>/dev/null || true
  fi

  local limits
  limits="$(kubectl get pods -n "$ns" -l "$sel" \
    -o 'jsonpath={.items[*].spec.containers[*].resources.limits}' 2>/dev/null || true)"
  [ -n "$limits" ] || echo "Resource limits     : none set — CPU and memory faults are unbounded"

  local probes
  probes="$(kubectl get pods -n "$ns" -l "$sel" \
    -o 'jsonpath={.items[*].spec.containers[*].readinessProbe}' 2>/dev/null || true)"
  [ -n "$probes" ] || echo "Readiness probes    : none — traffic will reach pods that are not ready"
  echo "────────────────────────────────────────────────"
}

# ── Steady-state probing ─────────────────────────────────────────────────
# PROBE_URL forms:
#   https://host/path      probed directly from the runner
#   svc:name:port/path     port-forwarded from inside the cluster
# Samples land in $SAMPLES as "http_code total_seconds" lines.
PROBE_PF_PID=""

probe_start() {
  local ns="$1" url="$2"
  [ -n "$url" ] || return 0

  if [ "${url#svc:}" != "$url" ]; then
    local rest name port path
    rest="${url#svc:}"
    name="${rest%%:*}"
    rest="${rest#*:}"
    port="${rest%%/*}"
    path="/${rest#*/}"
    [ "$path" = "/${rest}" ] && path="/"
    valid_k8s_name "$name" || die "Probe service name '$name' is not valid."
    valid_int "$port" 1 65535 || die "Probe port '$port' is not valid."

    kubectl port-forward -n "$ns" "svc/$name" "18080:$port" >/dev/null 2>&1 &
    PROBE_PF_PID=$!
    sleep 3
    PROBE_TARGET="http://127.0.0.1:18080${path}"
  else
    case "$url" in
      http://*|https://*) PROBE_TARGET="$url" ;;
      *) die "Probe URL must start with http://, https:// or svc:" ;;
    esac
  fi
  export PROBE_TARGET
  log "probe target: $PROBE_TARGET"
}

probe_stop() {
  [ -n "$PROBE_PF_PID" ] && kill "$PROBE_PF_PID" 2>/dev/null || true
  PROBE_PF_PID=""
}

# probe_sample <seconds> <outfile> — appends samples for the given window.
probe_sample() {
  local secs="$1" out="$2" end
  [ -n "${PROBE_TARGET:-}" ] || return 0
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}\n' "$PROBE_TARGET" >> "$out" 2>/dev/null \
      || echo "000 5.000" >> "$out"
    sleep 1
  done
}

# ── SLO evaluation ───────────────────────────────────────────────────────
# SLO string: "status=200;p95_ms=500;err_pct=5;min_ready=2"
slo_field() {
  printf '%s' "${1:-}" | tr ';' '\n' | sed -n "s/^${2}=//p" | head -1
}

# Prints "PASS <detail>" or "FAIL <detail>"; returns 1 on breach.
slo_evaluate() {
  local samples="$1" slo="$2" ns="$3" sel="$4"
  local want_status p95_max err_max min_ready
  want_status="$(slo_field "$slo" status)"
  p95_max="$(slo_field "$slo" p95_ms)"
  err_max="$(slo_field "$slo" err_pct)"
  min_ready="$(slo_field "$slo" min_ready)"

  local breaches="" detail=""

  if [ -s "$samples" ]; then
    local total bad errpct p95
    total="$(wc -l < "$samples" | tr -d ' ')"
    bad="$(awk -v w="${want_status:-200}" '$1 != w' "$samples" | wc -l | tr -d ' ')"
    errpct=$(( bad * 100 / (total > 0 ? total : 1) ))
    p95="$(awk '{print $2*1000}' "$samples" | sort -n | \
      awk '{a[NR]=$1} END {if (NR==0) {print 0} else {i=int(NR*0.95); if(i<1)i=1; printf "%d", a[i]}}')"
    detail="samples=$total errors=$bad (${errpct}%) p95=${p95}ms"

    [ -n "$err_max" ] && [ "$errpct" -gt "$err_max" ] && \
      breaches="$breaches error-rate ${errpct}%>${err_max}%;"
    [ -n "$p95_max" ] && [ "$p95" -gt "$p95_max" ] && \
      breaches="$breaches latency ${p95}ms>${p95_max}ms;"
  fi

  if [ -n "$min_ready" ]; then
    local ready
    ready="$(ready_pods "$ns" "$sel")"
    detail="$detail ready=$ready"
    [ "$ready" -lt "$min_ready" ] && \
      breaches="$breaches ready ${ready}<${min_ready};"
  fi

  if [ -n "$breaches" ]; then
    printf 'FAIL %s | breached:%s\n' "$detail" "$breaches"
    return 1
  fi
  printf 'PASS %s\n' "$detail"
  return 0
}
