// ============================================================
//  ChaosLab — chaos.js
//  chaoslab.eknathalabs.com · EknathaLabs
//
//  SETUP REQUIRED BEFORE FIRST USE:
//  1. Set REPO to "your-github-username/chaoslab"
//  2. Set TOKEN to a fine-grained PAT with Actions:write scope
//     → github.com/settings/tokens → Fine-grained tokens
//     → Repository access: chaoslab → Permissions: Actions (write)
//  3. Never commit a real token to a public repo.
// ============================================================

const CFG = {
  REPO:  'eknatha/chaoslab',   // ← YOUR GITHUB USERNAME/REPO
  TOKEN: '',                    // ← YOUR FINE-GRAINED PAT
};

// ── State ────────────────────────────────────────────────────
let selWorkflow  = 'pod-kill.yml';
let selFaultName = 'Pod Kill';
const runHistory = [];

// ── Fault selector ───────────────────────────────────────────
function pickFault(el) {
  document.querySelectorAll('.fc').forEach(c => c.classList.remove('active'));
  el.classList.add('active');
  selWorkflow  = el.dataset.w;
  selFaultName = el.dataset.n;

  const slug = selWorkflow.replace('.yml', '');
  document.getElementById('bslug').textContent =
    `chaos run --fault ${slug}${document.getElementById('dry-run').checked ? ' --dry-run' : ''}`;

  // Show extra fields for cpu-stress and net-delay
  document.getElementById('xrow').style.display =
    (slug === 'cpu-stress' || slug === 'net-delay') ? 'grid' : 'none';

  tlog(`Selected fault: ${selFaultName} (${selWorkflow})`, 'inf');
}

// ── Dry-run toggle label ─────────────────────────────────────
function syncDryLabel() {
  const on  = document.getElementById('dry-run').checked;
  const lbl = document.getElementById('dry-lbl');
  lbl.textContent = on ? '🔵 Dry run ON — safe' : '🔴 Dry run OFF — LIVE';
  lbl.style.color = on ? '' : 'var(--red)';

  const slug = selWorkflow.replace('.yml', '');
  document.getElementById('bslug').textContent =
    `chaos run --fault ${slug}${on ? ' --dry-run' : ''}`;
}

// ── Run experiment ───────────────────────────────────────────
async function runExperiment() {
  const ns     = document.getElementById('ns').value.trim();
  const sel    = document.getElementById('sel').value.trim();
  const dur    = document.getElementById('dur').value;
  const blast  = document.getElementById('blast').value;
  const cpuw   = document.getElementById('cpuw').value;
  const dms    = document.getElementById('dms').value;
  const dryRun = document.getElementById('dry-run').checked;

  // Validation
  if (!ns)  { tlog('✗ Namespace is required.', 'err'); return; }
  if (!sel) { tlog('✗ Label selector is required (e.g. app=frontend).', 'err'); return; }

  if (ns === 'kube-system') {
    tlog('✗ BLOCKED: kube-system is protected and cannot be targeted.', 'err');
    return;
  }

  if (!CFG.TOKEN) {
    tlog('✗ CONFIG.TOKEN not set. Open chaos.js and add your GitHub PAT.', 'err');
    tlog('  → github.com/settings/tokens → Fine-grained → Actions:write', 'inf');
    return;
  }

  setStatus('running');
  setBtnState(true);

  tlog('─'.repeat(48), 'dim');
  tlog(`▶ Fault: ${selFaultName}`, 'inf');
  tlog(`  ns:${ns}  sel:${sel}  dur:${dur}s  blast:${blast}%  dry:${dryRun}`, 'dim');
  tlog(`  Workflow: ${selWorkflow}`, 'dim');
  tlog('Dispatching to GitHub Actions...', 'wrn');

  // Build inputs payload
  const inputs = {
    namespace:    ns,
    selector:     sel,
    duration:     String(dur),
    blast_radius: String(blast),
    dry_run:      String(dryRun),
  };
  if (selWorkflow === 'cpu-stress.yml') inputs.cpu_workers = String(cpuw);
  if (selWorkflow === 'net-delay.yml')  inputs.delay_ms    = String(dms);

  try {
    const res = await fetch(
      `https://api.github.com/repos/${CFG.REPO}/actions/workflows/${selWorkflow}/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization':        `Bearer ${CFG.TOKEN}`,
          'Accept':               'application/vnd.github+json',
          'Content-Type':         'application/json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        body: JSON.stringify({ ref: 'main', inputs }),
      }
    );

    if (res.status === 204) {
      tlog('✓ Workflow dispatched successfully!', 'ok');
      tlog(`  Monitor → github.com/${CFG.REPO}/actions`, 'inf');
      if (!dryRun) tlog('⚠ Live run active — monitor your cluster.', 'wrn');
      addRun(selFaultName, ns, sel, dryRun);
    } else {
      const body = await res.json().catch(() => ({}));
      tlog(`✗ Dispatch failed (HTTP ${res.status}): ${body.message || 'unknown'}`, 'err');
      if (res.status === 401) tlog('  Token expired or missing Actions:write scope.', 'wrn');
      if (res.status === 404) tlog('  Check CFG.REPO — repo or workflow file not found.', 'wrn');
      if (res.status === 422) tlog('  Workflow file not on main branch yet — push it first.', 'wrn');
    }
  } catch (err) {
    tlog(`✗ Network error: ${err.message}`, 'err');
  } finally {
    setStatus('ready');
    setBtnState(false);
  }
}

// ── Emergency rollback ───────────────────────────────────────
async function emergencyRollback() {
  if (!CFG.TOKEN) {
    tlog('✗ CONFIG.TOKEN not set — cannot trigger rollback.', 'err');
    return;
  }

  const ns = document.getElementById('ns').value.trim() || 'default';

  const confirmed = confirm(
    `Emergency rollback for namespace: "${ns}"\n\n` +
    `This will:\n` +
    `• Delete all chaos pods and DaemonSets\n` +
    `• Uncordon all cordoned nodes\n` +
    `• Rolling restart all deployments\n\n` +
    `Confirm?`
  );
  if (!confirmed) return;

  setStatus('rolling back');
  tlog('─'.repeat(48), 'dim');
  tlog(`⚠ Emergency rollback triggered → ns:${ns}`, 'wrn');

  try {
    const res = await fetch(
      `https://api.github.com/repos/${CFG.REPO}/actions/workflows/rollback.yml/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization':        `Bearer ${CFG.TOKEN}`,
          'Accept':               'application/vnd.github+json',
          'Content-Type':         'application/json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        body: JSON.stringify({ ref: 'main', inputs: { namespace: ns } }),
      }
    );

    if (res.status === 204) {
      tlog('✓ Rollback workflow dispatched.', 'ok');
      tlog(`  Monitor → github.com/${CFG.REPO}/actions`, 'inf');
    } else {
      tlog(`✗ Rollback failed (HTTP ${res.status})`, 'err');
    }
  } catch (err) {
    tlog(`✗ Network error: ${err.message}`, 'err');
  } finally {
    setStatus('ready');
  }
}

// ── Terminal log helpers ─────────────────────────────────────
function tlog(msg, cls = '') {
  const log  = document.getElementById('log');
  const now  = new Date().toTimeString().slice(0, 8);
  const line = document.createElement('div');
  line.className = 'll';
  line.innerHTML = `<span class="lt">${now}</span><span class="${cls}">${msg}</span>`;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
  document.getElementById('term-st').textContent =
    cls === 'ok' ? 'done' : cls || 'running';
}

function clearLog() {
  document.getElementById('log').innerHTML =
    '<div class="ll"><span class="lt">--:--:--</span><span class="dim">Log cleared.</span></div>';
  document.getElementById('term-st').textContent = 'idle';
}

function setStatus(txt) {
  document.getElementById('nav-status').textContent = txt;
  document.getElementById('term-st').textContent   = txt;
}

function setBtnState(disabled) {
  const btn = document.getElementById('run-btn');
  btn.disabled    = disabled;
  btn.textContent = disabled ? '⏳ Dispatching...' : '▶ Run Experiment';
}

// ── Recent runs list ─────────────────────────────────────────
function addRun(fault, ns, sel, dry) {
  runHistory.unshift({
    fault, ns, sel, dry,
    time: new Date().toLocaleTimeString(),
  });

  document.getElementById('runs').innerHTML =
    runHistory.slice(0, 10).map(r => `
      <div class="run-row">
        <div class="rdot ${r.dry ? 'rd-dry' : 'rd-ok'}"></div>
        <span class="rfault">${r.fault}</span>
        <span class="rns">ns:${r.ns}</span>
        <span class="rsel">${r.sel}</span>
        <span class="rtime">${r.time}</span>
        <span class="rbadge ${r.dry ? 'rb-dry' : 'rb-live'}">${r.dry ? 'dry-run' : 'live'}</span>
      </div>`).join('');
}

// ── Scroll fade-in observer ──────────────────────────────────
const fadeObs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      e.target.classList.add('in');
      fadeObs.unobserve(e.target);
    }
  });
}, { threshold: 0.08 });

// ── Init ────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  syncDryLabel();

  // Start fade observers
  document.querySelectorAll('.fade').forEach(el => fadeObs.observe(el));

  // Token status
  if (!CFG.TOKEN) {
    tlog('⚠ CONFIG.TOKEN not set — open chaos.js to configure.', 'wrn');
    tlog('  Dry run mode works without a token for UI preview.', 'dim');
  } else {
    tlog('✓ Token configured — ready to dispatch experiments.', 'ok');
  }
});
