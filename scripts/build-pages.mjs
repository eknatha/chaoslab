// Generates one static page per fault, a catalogue, sitemap.xml and robots.txt.
// Run from the repository root:  node scripts/build-pages.mjs
import fs from 'node:fs';
import vm from 'node:vm';
const html = fs.readFileSync('index.html', 'utf8');
const a = html.indexOf('/* @engine:start */'), b = html.indexOf('/* @engine:end */');
if (a < 0 || b < 0) throw new Error('engine markers not found in index.html');
const { FAULTS, DOCS, CATS } = vm.runInNewContext(html.slice(a, b) + ';({FAULTS,DOCS,CATS})');
const SITE = 'https://chaoslab.eknathalabs.com';
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const css = 'body{background:#080a0d;color:#d6dde8;font:16px/1.7 system-ui,sans-serif;margin:0}main{max-width:760px;margin:0 auto;padding:2.5rem 1.25rem}a{color:#00d4ff}h1{font-size:2rem;line-height:1.2}.c{border:1px solid #232a35;border-radius:10px;padding:1rem 1.2rem;margin:1rem 0;background:#0f1319}.cta{display:inline-block;background:#00ff88;color:#04100a;font-weight:700;padding:.7rem 1.2rem;border-radius:8px;text-decoration:none}small{color:#8d9aad}';
const page = (title, desc, path, body) => `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><meta name="description" content="${esc(desc)}"><link rel="canonical" href="${SITE}${path}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${SITE}/og.png"><meta name="twitter:card" content="summary_large_image"><style>${css}</style></head><body><main>${body}</main></body></html>\n`;
fs.mkdirSync('faults', { recursive: true });
const urls = ['/', '/faults/', '/linter.html', '/reports/'];
for (const [id, f] of Object.entries(FAULTS)) {
  const docs = (f.docs || []).filter(k => DOCS[k]).map(k => `<li><a href="${esc(DOCS[k][1])}" rel="noopener">${esc(DOCS[k][0])}</a></li>`).join('');
  const body = `<p><a href="/faults/">All faults</a> / ${esc(CATS[f.cat])}</p><h1>${esc(f.label)}: chaos experiment</h1><p>${esc(f.desc)}</p>
<div class="c"><b>What it tests</b><br>${esc(f.tests)}</div><div class="c"><b>The hypothesis holds when</b><br>${esc(f.holds)}</div><div class="c"><b>It breaks when</b><br>${esc(f.breaks)}</div>
${docs ? `<h2>Reference</h2><ul>${docs}</ul>` : ''}<p><a class="cta" href="/#f=${encodeURIComponent(id)}">Run this experiment in your browser</a></p>
<p><small>${f.live ? 'Runs in the simulator and against a live cluster.' : 'Simulator only today. Export it as a manifest from the Export tab.'}</small></p>`;
  fs.mkdirSync(`faults/${id}`, { recursive: true });
  fs.writeFileSync(`faults/${id}/index.html`, page(`${f.label} chaos experiment — ChaosLab`, `${f.label}: ${f.tests}. Run it against a simulated system in your browser.`, `/faults/${id}/`, body));
  urls.push(`/faults/${id}/`);
}
const list = Object.entries(CATS).map(([c, n]) => `<h2>${esc(n)}</h2><ul>${Object.entries(FAULTS).filter(([, f]) => f.cat === c).map(([id, f]) => `<li><a href="/faults/${id}/">${esc(f.label)}</a> — ${esc(f.tests)}</li>`).join('')}</ul>`).join('');
fs.writeFileSync('faults/index.html', page('Chaos experiment catalogue — ChaosLab', `${Object.keys(FAULTS).length} faults across compute, network, data, cloud, delivery and AI services, from pod kills to LLM outages.`, '/faults/', `<h1>Fault catalogue</h1>${list}`));
fs.writeFileSync('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map(u => `  <url><loc>${SITE}${u}</loc></url>`).join('\n')}\n</urlset>\n`);
fs.writeFileSync('robots.txt', `User-agent: *\nAllow: /\nSitemap: ${SITE}/sitemap.xml\n`);
console.log('wrote', urls.length, 'pages');
