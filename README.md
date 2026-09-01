# ChaosLab

**[chaoslab.eknathalabs.com](https://chaoslab.eknathalabs.com)** · part of [EknathaLabs](https://eknathalabs.com)

Break Kubernetes on purpose, and find out whether it held.

ChaosLab has three parts:

| | |
|---|---|
| **[Simulator](https://chaoslab.eknathalabs.com/)** | A Kubernetes cluster that runs in your browser. Ten fault types, real reconciliation semantics, no cluster and no credentials needed. |
| **[Resilience linter](https://chaoslab.eknathalabs.com/linter.html)** | Paste a Deployment and find out which experiments it would survive, before running any of them. |
| **Live mode** | The same experiment dispatched at your own cluster through GitHub Actions, with a hypothesis, abort conditions and guaranteed cleanup. |
| **Incident reports** | Every run ends in a written postmortem: timeline, time to detection, time to recovery, contributing factors and action items with the diffs attached. |
| **Terraform bootstrap** | One `apply` provisions the whole live-mode setup — scoped RBAC, federated credentials, environments, approval gates and the namespace allowlist. |

Zero servers, zero monthly bills, no build step.

---

## Faults

| Fault | What it tests |
|---|---|
| `pod-kill` | ReplicaSet self-healing, PodDisruptionBudgets, startup time |
| `container-kill` | restartPolicy, liveness probes, crash loop backoff |
| `cpu-stress` | CPU limits, HPA reaction time, latency under contention |
| `memory-stress` | memory limits, OOMKilled handling |
| `disk-fill` | ephemeral storage limits, kubelet eviction thresholds |
| `net-delay` | client timeouts, circuit breakers, probe timeouts |
| `net-loss` | retry policy, TCP behaviour, probe failure thresholds |
| `dns-blackhole` | DNS caching, connection reuse, dependency failure handling |
| `node-drain` | PodDisruptionBudgets, spare capacity, rescheduling time |
| `zone-outage` | topology spread constraints, multi-zone capacity |

Pod-level faults respect the blast radius cap. Node-level faults are pinned by
node affinity to the nodes already hosting your target pods, and never to a
control-plane node.

---

## Hypothesis and abort conditions

An experiment without a hypothesis is just an outage. Every run declares what
should stay true:

```
status=200;p95_ms=500;err_pct=5;min_ready=2
```

The workflow then:

1. **Measures steady state** before injecting anything. If the SLO is already
   breached, the run stops — there is no hypothesis to test against a system
   that is already unhealthy.
2. **Injects the fault** and re-evaluates every ten seconds.
3. **Aborts on the first breach** when `abort_on_breach` is on, removing the
   fault and running a full rollback rather than riding out the duration.
4. **Verifies recovery** against the ready pod count from before the fault.
5. **Fails the run** if the hypothesis broke or the workload did not come back,
   so a red X in Actions means something real.

Set `probe_url` to an external URL, or to `svc:name:port/path` to probe a
private Service through a port-forward from inside the cluster.

---

## Live mode setup

### The short version

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit it
terraform init && terraform apply
```

That creates a service account scoped to only the namespaces you name, the
RBAC it needs and nothing more, the `chaos-dry` and `chaos-live` environments
with an approval gate, the `CHAOS_ALLOWED_NAMESPACES` variable, and either a
short-lived kubeconfig secret or — better — a federated IAM role.

Two authentication modes:

| `auth_mode` | What happens |
|---|---|
| `kubeconfig` | Mints a bound service account token with a fixed lifetime and writes `KUBECONFIG_DATA` and `CLUSTER_CONTEXT`. Works against any cluster, including kind. |
| `oidc` | Creates a GitHub OIDC provider and an IAM role, and writes `AWS_ROLE_ARN`. **No cluster credential is stored anywhere.** The workflow exchanges its OIDC token for a short-lived AWS credential at run time. |

Prefer `oidc` where you can. The trust policy is pinned to one repository and
one environment:

```
repo:<owner>/chaoslab:environment:chaos-live
```

which means a workflow run outside the `chaos-live` environment cannot assume
the role at all. The approval gate stops being a convenience and becomes a
security boundary.

Node-level faults need cluster-wide cordon rights, so they are opt-in. Leave
`node-drain` and `zone-outage` out of `enabled_faults` and the extra
ClusterRole is never created.

### Doing it by hand instead

`Settings → Secrets and variables → Actions`

| Secret | Value |
|---|---|
| `KUBECONFIG_DATA` | `base64 -w 0 ~/.kube/config` |
| `CLUSTER_CONTEXT` | `kubectl config current-context` |

Optionally add a `CHAOS_ALLOWED_NAMESPACES` variable (`staging chaos-demo`) to
refuse everything else before the cluster is contacted, and add required
reviewers to a `chaos-live` environment under `Settings → Environments`.

Then `Settings → Pages → Branch: main / root`.

### Running one

Open the site, switch to live mode, and paste a fine-grained token with
**Actions: write** on this repository only. The token is held in the browser
tab's session storage and is never written to the page or the repository.

Or skip the UI entirely:

```bash
gh workflow run chaos.yml \
  -f fault=pod-kill \
  -f namespace=chaos-demo \
  -f selector=app=frontend \
  -f duration=60 \
  -f blast_radius=30 \
  -f dry_run=false \
  -f probe_url=svc:frontend:80/ \
  -f slo="status=200;p95_ms=500;err_pct=5;min_ready=3" \
  -f abort_on_breach=true
```

---

## Incident reports

Every run produces a postmortem, in the run's step summary and as an artifact.
The simulator produces the same document in the browser, with copy and
download buttons.

It is not a log dump. It contains:

- **What happened**, in prose, distinguishing a workload that broke its
  thresholds from one that held them but never recovered on its own.
- **Impact**, as before-and-during-fault numbers against the thresholds you set.
- **Time to detection** and **time to recovery**, measured from injection and
  from the first drop below full strength.
- **A timeline** of what the control plane actually did — evictions granted,
  evictions refused, nodes cordoned, probes passing again.
- **Contributing factors**, derived from the posture of the workload that was
  hit rather than from a fixed checklist.
- **Action items** with the exact YAML to apply.
- **The next experiment to run**, so the report ends with a test rather than
  a wish.

The point is that a chaos run should leave you with the artefact you would
have written after a real incident, without the incident.

## Try it locally

```bash
kind create cluster --name chaoslab --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF

kubectl apply -f demo/app.yaml
kind get kubeconfig --name chaoslab | base64 -w 0   # paste into KUBECONFIG_DATA
```

Run `node-drain` against `app=frontend` in `chaos-demo` with
`min_ready=3`. It will fail: there is no PodDisruptionBudget, so the drain
evicts everything on the node.

Then:

```bash
kubectl apply -f demo/hardened.yaml
```

Run the identical experiment again. The eviction is refused, the floor holds,
and the run passes. That two-file diff is the whole lesson.

---

## Guardrails

- **Protected namespaces.** `kube-system`, `kube-public`, `kube-node-lease`,
  `cert-manager`, `istio-system` and `gatekeeper-system` are always refused.
  Whitespace is stripped before the check, and names must be valid RFC 1123
  labels, so injection attempts fail validation rather than reaching a shell.
- **No interpolated inputs.** Workflow inputs reach the shell through `env:`
  only. Nothing is substituted into a `run:` block.
- **Bounded blast radius.** Pod faults hit a random sample capped at the
  chosen percentage. Node faults are pinned to nodes hosting the target pods.
- **Cleanup that survives failure.** Removal runs on success, failure, timeout
  and cancellation. Network emulation carries a signal trap plus a follow-up
  scrub job, so a node is never left with a stray `tc` queue.
- **One experiment per namespace.** Serialised by a concurrency group.
- **Least privilege.** Workflows request only `contents: read` and, when OIDC
  is in use, `id-token: write`. The in-cluster service account is scoped to the
  namespaces you named, with no access to secrets or configmaps, and node-level
  permissions only if you asked for them.

---

## Layout

```
chaoslab/
├── index.html              simulator, hypothesis engine, live dispatch
├── linter.html             resilience linter
├── 404.html
├── reports/index.html      history, read from the public Actions API
├── demo/
│   ├── app.yaml            deliberately fragile three-tier workload
│   └── hardened.yaml       the fix
├── .github/workflows/
│   ├── chaos.yml           every fault, one hardened pipeline
│   └── rollback.yml
├── scripts/
│   ├── lib.sh              guards, probes, SLO evaluation, timeline
│   ├── chaos.sh            fault injection and cleanup
│   ├── postmortem.sh       incident report from a finished run
│   └── rollback.sh
└── terraform/
    ├── main.tf             one apply for the whole live-mode setup
    └── modules/
        ├── aws-oidc/       federated credentials, no stored kubeconfig
        ├── cluster-access/ scoped service account and RBAC
        └── github-config/  environments, approval gates, variables
```

Every page is a single self-contained file with no external assets, so the
simulator and the linter keep working offline once loaded.

---

## License

MIT
