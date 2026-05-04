// ============================================================
//  ChaosLab — chaos.js
//  chaoslab.eknathalabs.com · EknathaLabs
//
//  SETUP: Fill in REPO and TOKEN before first use.
//  TOKEN: Create a fine-grained PAT at github.com/settings/tokens
//         Scope: Actions (write) for this repo only.
//  ⚠ Never commit a real token to a public repo.
//     Use a runtime prompt or environment variable instead.
// ============================================================

const CONFIG = {
  REPO:  'eknatha/chaoslab',   // ← your GitHub username/repo
  TOKEN: '',                    // ← your fine-grained PAT (Actions:write)
};

// ============================================================
//  State
// ============================================================
let selectedWorkflow  = 'pod-kill.yml';
let selectedFaultName = 'Pod Kill';
const runs = [];

// ============================================================
//  Fault selector
// ============================================================
function selectFault(el) {
  document.querySelectorAll('.fault-card').forEach(c => c.classList.remove('active'));
  el.classList.add('active');
  selectedWorkflow  = el.dataset.workflow;
  selectedFaultName = el.dataset.name;

  // Update builder title
  const slug = selectedWorkflow.replace('.yml', '');
  document.getElementById('builder-title').textContent =
    `chaos run --fault ${slug}`;

  // Show/hide extra fields
  const cpuRow = document.getElementById('cpu-workers-row');
  cpuRow.style.display = (slug === 'cpu-stress' || slug === 'net-delay') ? 'grid' : 'none';

  log(`Selected fault: ${selectedFaultName}`, 'info');
}

// ============================================================
//  Dry run label
// ============================================================
function updateDryLabel() {
  const on = document.getElementById('dry-run').checked;
  document.getElementById('dry-label').textContent =
    on ? '🔵 Dry run ON — safe to test' : '🔴 Dry run OFF — LIVE run';
  document.getElementById('dry-label').style.color =
    on ? 'var(--muted)' : 'var(--danger)';
}

// ============================================================
//  Run experiment
// ============================================================
async function runExperiment() {
  const namespace   = document.getElementById('namespace').value.trim();
  const selector    = document.getElementById('selector').value.trim();
  const duration    = document.getElementById('duration').value;
  const blast       = document.getElementById('blast').value;
  const cpuWorkers  = document.getElementById('cpu-workers')?.value || '4';
  const delayMs     = document.getElementById('delay-ms')?.value || '500';
  const dryRun      = document.getElementById('dry-run').checked;

  // Validation
  if (!namespace) { log('✗ Namespace is required.', 'err'); return; }
  if (!selector)  { log('✗ Label selector is required (e.g. app=frontend).', 'err'); return; }

  if (namespace === 'kube-system') {
    log('✗ BLOCKED: kube-system namespace is protected and cannot be targeted.', 'err');
    return;
  }

  if (!CONFIG.TOKEN) {
    log('✗ No GitHub token set. Open chaos.js and set CONFIG.TOKEN.', 'err');
    log('  → github.com/settings/tokens → Fine-grained token → Actions:write', 'info');
    return;
  }

  setStatus('running');
  setRunBtn(true);

  log('─'.repeat(50), 'dim');
  log(`▶ Experiment: ${selectedFaultName}`, 'info');
  log(`  Namespace   : ${namespace}`, 'dim');
  log(`  Selector    : ${selector}`, 'dim');
  log(`  Duration    : ${duration}s`, 'dim');
  log(`  Blast radius: ${blast}%`, 'dim');
  log(`  Dry run     : ${dryRun}`, dryRun ? 'dim' : 'warn');
  log(`  Workflow    : ${selectedWorkflow}`, 'dim');
  log('Dispatching to GitHub Actions...', 'warn');

  // Build inputs based on workflow type
  const inputs = {
    namespace,
    selector,
    duration: String(duration),
    blast_radius: String(blast),
    dry_run: String(dryRun),
  };
  if (selectedWorkflow === 'cpu-stress.yml') inputs.cpu_workers = String(cpuWorkers);
  if (selectedWorkflow === 'net-delay.yml')  inputs.delay_ms    = String(delayMs);

  try {
    const res = await fetch(
      `https://api.github.com/repos/${CONFIG.REPO}/actions/workflows/${selectedWorkflow}/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${CONFIG.TOKEN}`,
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        body: JSON.stringify({ ref: 'main', inputs }),
      }
    );

    if (res.status === 204) {
      log('✓ Workflow dispatched successfully!', 'ok');
      log(`  View run → github.com/${CONFIG.REPO}/actions`, 'info');
      if (!dryRun) {
        log('⚠ Live run in progress — monitor your cluster.', 'warn');
      }
      addRun(selectedFaultName, namespace, selector, dryRun, 'dispatched');
    } else {
      const body = await res.json().catch(() => ({}));
      log(`✗ Dispatch failed (HTTP ${res.status}): ${body.message || 'unknown error'}`, 'err');
      if (res.status === 401) log('  Check your TOKEN — it may be expired or lack Actions:write scope.', 'warn');
      if (res.status === 404) log('  Check your REPO name in CONFIG.', 'warn');
      if (res.status === 422) log('  Workflow not found — ensure the .yml file is on the main branch.', 'warn');
    }
  } catch (err) {
    log(`✗ Network error: ${err.message}`, 'err');
  } finally {
    setStatus('ready');
    setRunBtn(false);
  }
}

// ============================================================
//  Emergency rollback
// ============================================================
async function triggerRollback() {
  if (!CONFIG.TOKEN) { log('✗ No GitHub token set. Cannot trigger rollback.', 'err'); return; }

  const namespace = document.getElementById('namespace').value.trim() || 'default';

  if (!confirm(`Emergency rollback for namespace: "${namespace}"?\n\nThis will:\n• Delete all chaos pods\n• Remove chaos DaemonSets\n• Uncordon all nodes\n• Restart all deployments\n\nConfirm?`)) return;

  setStatus('rolling back');
  log('─'.repeat(50), 'dim');
  log(`⚠ EMERGENCY ROLLBACK triggered for namespace: ${namespace}`, 'warn');

  try {
    const res = await fetch(
      `https://api.github.com/repos/${CONFIG.REPO}/actions/workflows/rollback.yml/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${CONFIG.TOKEN}`,
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ref: 'main', inputs: { namespace } }),
      }
    );

    if (res.status === 204) {
      log('✓ Rollback workflow dispatched.', 'ok');
      log(`  View rollback → github.com/${CONFIG.REPO}/actions`, 'info');
    } else {
      log(`✗ Rollback dispatch failed (HTTP ${res.status})`, 'err');
    }
  } catch (err) {
    log(`✗ Network error: ${err.message}`, 'err');
  } finally {
    setStatus('ready');
  }
}

// ============================================================
//  Log helpers
// ============================================================
function log(msg, type = '') {
  const body = document.getElementById('log');
  const now  = new Date().toTimeString().slice(0, 8);
  const line = document.createElement('div');
  line.className = 'log-line';
  line.innerHTML = `<span class="lt">${now}</span><span class="lm ${type}">${msg}</span>`;
  body.appendChild(line);
  body.scrollTop = body.scrollHeight;
  document.getElementById('log-status').textContent = type === 'ok' ? 'done' : type || 'running';
}

function clearLog() {
  document.getElementById('log').innerHTML =
    '<div class="log-line"><span class="lt">--:--:--</span><span class="lm dim">Log cleared.</span></div>';
  document.getElementById('log-status').textContent = 'idle';
}

function setStatus(text) {
  document.getElementById('status-text').textContent = text;
}

function setRunBtn(disabled) {
  const btn = document.getElementById('run-btn');
  btn.disabled = disabled;
  btn.textContent = disabled ? '⏳ Dispatching...' : '▶ Run Experiment';
}

// ============================================================
//  Recent runs table
// ============================================================
function addRun(fault, ns, selector, dry, status) {
  const now = new Date().toLocaleTimeString();
  runs.unshift({ fault, ns, selector, dry, status, time: now });

  const list = document.getElementById('runs-list');
  list.innerHTML = runs.slice(0, 10).map(r => `
    <div class="run-item">
      <div class="run-dot ${r.dry ? 'rd-dry' : 'rd-ok'}"></div>
      <span class="run-fault">${r.fault}</span>
      <span class="run-ns">ns:${r.ns}</span>
      <span class="run-sel">${r.selector}</span>
      <span class="run-time">${r.time}</span>
      <span class="run-badge ${r.dry ? 'rb-dry' : 'rb-live'}">${r.dry ? 'dry-run' : 'live'}</span>
    </div>`).join('');
}

// ============================================================
//  Init
// ============================================================
document.addEventListener('DOMContentLoaded', () => {
  updateDryLabel();

  if (!CONFIG.TOKEN) {
    log('⚠ No GitHub token configured. Set CONFIG.TOKEN in chaos.js.', 'warn');
    log('  Dry run mode works without a token for preview only.', 'dim');
  } else {
    log('✓ Token configured. Ready to dispatch experiments.', 'ok');
  }
});
