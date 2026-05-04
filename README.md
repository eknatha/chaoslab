# ChaosLab — Kubernetes Chaos Simulator

> **chaoslab.eknathalabs.com** · Part of [EknathaLabs](https://eknathalabs.com)

Inject real failures into Kubernetes clusters. Learn resilience engineering by intentionally breaking things in a safe, controlled environment — powered entirely by GitHub Actions and GitHub Pages. Zero servers. Zero monthly bills.

---

## Quick Start

1. Fork / create this repo on GitHub
2. Add GitHub Secrets (see Setup below)
3. Set `REPO` and `TOKEN` in `chaos.js`
4. Enable GitHub Pages → `main` / root
5. Open `chaoslab.eknathalabs.com` and run your first experiment

---

## Fault Types

| Fault | What it tests | Workflow |
|-------|--------------|----------|
| 💀 Pod Kill | ReplicaSet self-healing | `pod-kill.yml` |
| 🔥 CPU Stress | HPA scaling, resource limits | `cpu-stress.yml` |
| 🌐 Network Delay | Timeouts, circuit breakers | `net-delay.yml` |
| 🖥️ Node Drain | Pod rescheduling, PodDisruptionBudgets | `node-drain.yml` |

---

## Setup

### 1. GitHub Secrets

Go to `Settings → Secrets and variables → Actions`:

| Secret | Value |
|--------|-------|
| `KUBECONFIG_DATA` | `base64 -w 0 ~/.kube/config` |
| `CLUSTER_CONTEXT` | `kubectl config current-context` |

### 2. chaos.js

Edit `chaos.js` and set:

```js
const CONFIG = {
  REPO:  'your-username/chaoslab',
  TOKEN: 'ghp_xxxx',  // Fine-grained PAT: Actions write scope
};
```

> Create token at: `github.com/settings/tokens → Fine-grained tokens → Actions: write`

### 3. GitHub Pages

`Settings → Pages → Branch: main / root → Save`

Custom domain: `chaoslab.eknathalabs.com`

---

## Safety Guardrails

- `kube-system` namespace is **always** blocked
- Blast radius capped at your chosen % (default 30%)
- **Dry run ON by default** — safe to test without cluster changes
- Every workflow has an `always:` cleanup/rollback block
- Emergency rollback button available in UI at all times
- Full audit trail in GitHub Actions run history

---

## Repo Structure

```
chaoslab/
├── index.html                   ← Simulator UI (GitHub Pages)
├── chaos.js                     ← UI logic + GitHub API dispatch
├── assets/
│   └── style.css                ← All styles
├── .github/
│   └── workflows/
│       ├── pod-kill.yml
│       ├── cpu-stress.yml
│       ├── net-delay.yml
│       ├── node-drain.yml
│       └── rollback.yml         ← Emergency rollback
├── scripts/
│   ├── pod-kill.sh
│   ├── cpu-stress.sh
│   ├── net-delay.sh
│   └── rollback.sh
└── reports/
    └── index.html               ← Experiment reports dashboard
```

---

## Local Cluster (kind)

```bash
# Install kind
brew install kind

# Create cluster
kind create cluster --name chaos-lab

# Deploy a test app
kubectl create deployment nginx --image=nginx --replicas=5
kubectl expose deployment nginx --port=80

# Get kubeconfig for GitHub Secret
kind get kubeconfig --name chaos-lab | base64 -w 0
```

---

## License

MIT © 2026 EknathaLabs
