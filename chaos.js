// ============================================================
//  ChaosLab — chaos.js
//  Configure the two variables below before first use.
// ============================================================

const CONFIG = {
  // Your GitHub repo: "username/repo-name"
  REPO: 'eknatha/chaoslab',

  // Fine-grained PAT with Actions: write scope for this repo.
  // DO NOT commit a real token — use a runtime input or
  // GitHub Codespaces secrets and set this from an env var.
  TOKEN: '',
};

// ============================================================
//  State
// ============================================================
let selectedWorkflow = 'pod-kill.yml';
let selectedFaultName = 'Pod Kill';
const runs = [];

// ============================================================
//  Fault selector
// ============================================================
function selectFault(el, workflow, name) {
  document.querySelectorAll('.fault-card').forEach(c => c.classList.remove('active'));
  el.classList.add('active');
  selectedWorkflow = workflow;
  selectedFaultName = name;
  document.getElementById('builder-title').textContent = `Fault: ${name}`;
  log(`Selected fault: ${name} (${workflow})`, 'info');
}

// ============================================================
//  Run experiment — dispatches GitHub Actions workflow
// ============================================================
async function runExperiment() {
  const namespace = document.getElementById('namespace').value.trim();
  const selector  = document.getElementById('selector').value.trim();
  const duration  = document.getElementById('duration').value;
  const blast     = document.getElementById('blast').value;
  const dryRun    = document.getElementById('dry-run').checked;

  // Basic validation
  if (!namespace) { log('Namespace is required.', 'err'); return; }
  if (!selector)  { log('Label selector is required (e.g. app=frontend).', 'err'); return; }
  if (!CONFIG.TOKEN) {
    log('No GitHub token configured. Set CONFIG.TOKEN in chaos.js.', 'err');
    return;
  }

  // Safety guard
  if (namespace === 'kube-system') {
    log('BLOCKED: kube-system namespace is protected and cannot be targeted.', 'err');
    return;
  }

  setStatus('running');
  setRunBtn(true);

  log(`Starting experiment: ${selectedFaultName}`, 'info');
  log(`Target: namespace=${namespace}  selector=${selector}`, 'dim');
  log(`Duration: ${duration}s  Blast radius: ${blast}%  Dry run: ${dryRun}`, 'dim');
  log(`Dispatching workflow: ${selectedWorkflow} ...`, 'warn');

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
        body: JSON.stringify({
          ref: 'main',
          inputs: {
            namespace,
            selector,
            duration: String(duration),
            blast_radius: String(blast),
            dry_run: String(dryRun),
          },
        }),
      }
    );

    if (res.status === 204) {
      log(`✓ Workflow dispatched successfully.`, 'ok');
      log(`Monitor progress → github.com/${CONFIG.REPO}/actions`, 'info');
      addRun(selectedFaultName, namespace, selector, dryRun);
    } else {
      const body = await res.json().catch(() => ({}));
      log(`✗ Dispatch failed (HTTP ${res.status}): ${body.message || 'unknown error'}`, 'err');
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
  if (!CONFIG.TOKEN) { log('No GitHub token configured.', 'err'); return; }

  const namespace = document.getElementById('namespace').value.trim() || 'default';
  log(`⚠ Emergency rollback triggered for namespace: ${namespace}`, 'warn');
  setStatus('rolling back');

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
//  Helpers
// ============================================================
function log(msg, type = '') {
  const body = document.getElementById('log');
  const now  = new Date().toTimeString().slice(0, 8);
  const line = document.createElement('div');
  line.className = 'log-line';
  line.innerHTML = `<span class="log-time">${now}</span><span class="${type}">${msg}</span>`;
  body.appendChild(line);
  body.scrollTop = body.scrollHeight;
}

function clearLog() {
  document.getElementById('log').innerHTML =
    '<div class="log-line"><span class="log-time">--:--:--</span><span class="dim">Log cleared.</span></div>';
}

function setStatus(text) {
  document.getElementById('status-text').textContent = text;
  document.getElementById('log-status').textContent = text;
}

function setRunBtn(disabled) {
  const btn = document.getElementById('run-btn');
  btn.disabled = disabled;
  btn.textContent = disabled ? '⏳ Running...' : '▶ Run Experiment';
}

function addRun(fault, ns, selector, dry) {
  const now = new Date().toLocaleTimeString();
  runs.unshift({ fault, ns, selector, dry, time: now });

  const list = document.getElementById('runs-list');
  list.innerHTML = runs.slice(0, 8).map(r => `
    <div class="run-item">
      <div class="run-dot ${r.dry ? 'd-dry' : 'd-ok'}"></div>
      <span class="run-fault">${r.fault}</span>
      <span class="run-ns">ns: ${r.ns}</span>
      <span class="run-ns">${r.selector}</span>
      <span class="run-time">${r.time}</span>
      <span class="run-badge ${r.dry ? 'rb-dry' : 'rb-live'}">${r.dry ? 'dry-run' : 'live'}</span>
    </div>`).join('');
}
