# ChaosLab — Kubernetes Chaos Simulator

> **[chaoslab.eknathalabs.com](https://chaoslab.eknathalabs.com)** · Part of [EknathaLabs](https://eknathalabs.com)

Inject real failures into Kubernetes clusters. Learn resilience engineering by breaking things safely — powered entirely by **GitHub Actions + GitHub Pages**. Zero servers. Zero monthly bills.

---

## Setup

### 1. GitHub Secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | How to get the value |
|--------|---------------------|
| `KUBECONFIG_DATA` | Run: `base64 -w 0 ~/.kube/config` |
| `CLUSTER_CONTEXT` | Run: `kubectl config current-context` |

### 2. Edit chaos.js

Open `chaos.js` and update line 1:

```js
const CFG = {
  REPO:  'YOUR_USERNAME/chaoslab',   // ← your GitHub repo
  TOKEN: 'ghp_xxxx',                 // ← fine-grained PAT (Actions:write)
};
```

Create token at: `github.com/settings/tokens → Fine-grained → Actions: write`

### 3. Enable GitHub Pages

`Settings → Pages → Branch: main / root → Save`

Custom domain: `chaoslab.eknathalabs.com`

---

## Fault Types

| Fault | Workflow | What it tests |
|-------|----------|--------------|
| 💀 Pod Kill | `pod-kill.yml` | ReplicaSet self-healing |
| 🔥 CPU Stress | `cpu-stress.yml` | HPA, resource limits |
| 🌐 Network Delay | `net-delay.yml` | Timeouts, circuit breakers |
| 🖥️ Node Drain | `node-drain.yml` | PodDisruptionBudgets, autoscaler |

---

## File Structure

```
chaoslab/
├── index.html                    ← Simulator UI (self-contained)
├── reports/
│   └── index.html                ← Reports dashboard (self-contained)
├── .github/
│   └── workflows/
│       ├── pod-kill.yml
│       ├── cpu-stress.yml
│       ├── net-delay.yml
│       ├── node-drain.yml
│       └── rollback.yml
└── scripts/
    ├── pod-kill.sh
    ├── cpu-stress.sh
    ├── net-delay.sh
    └── rollback.sh
```

---

## Safety

- `kube-system` is always blocked
- Blast radius capped at selected % (default 30%)
- Dry run ON by default
- `always:` cleanup in every workflow
- Emergency rollback button in UI
- Full audit trail in GitHub Actions

---

## Local Cluster

```bash
brew install kind
kind create cluster --name chaos-lab
kubectl create deployment nginx --image=nginx --replicas=5
kind get kubeconfig --name chaos-lab | base64 -w 0
# Paste output into KUBECONFIG_DATA secret
```

---

## License

MIT © 2026 EknathaLabs
