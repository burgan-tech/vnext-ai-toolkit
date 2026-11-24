#!/usr/bin/env node
// Publishes a vNext workspace's components straight to ONE orchestrator, named out loud.
//
//   VNEXT_RUNTIME_URL=http://localhost:<port> node cluster-publish.mjs            publish
//   DRY=1 VNEXT_RUNTIME_URL=http://localhost:<port> node cluster-publish.mjs      list, send nothing
//   … node cluster-publish.mjs Workflows/hello                                    only matching paths
//
// Run from the workspace root (where vnext.config.json is). There is NO default target: a publish
// that guesses its runtime writes to another domain and reports success.
//
// Why not `wf update`: it deletes the existing key+version row from a Postgres it reaches on
// DB_HOST (localhost by default) before it publishes — against a forwarded cluster runtime that is
// the developer's LOCAL database. This script only speaks HTTP, to the origin it was given.
import fs from 'node:fs';
import path from 'node:path';

const fail = (msg) => { console.error(`✗ ${msg}`); process.exit(2); };
if (!fs.existsSync('vnext.config.json')) fail('no vnext.config.json here — run from the workspace root.');
const cfg = JSON.parse(fs.readFileSync('vnext.config.json', 'utf8'));
const origin = (process.env.VNEXT_RUNTIME_URL || '').replace(/\/+$/, '');
if (!/^https?:\/\//.test(origin)) fail('VNEXT_RUNTIME_URL is required (e.g. http://localhost:4290) — there is no default target.');
const dry = process.env.DRY === '1';
const filters = process.argv.slice(2);
console.error(`domain '${cfg.domain}': every call goes to ${origin}${dry ? ' (DRY — nothing is sent)' : ''}`);

// Dependency order: what a component refers to is published before it.
// `mappings` (sys-mappings helpers) go before anything that lists them in `scripts.helpers` (functions, workflows).
const ORDER = ['schemas', 'mappings', 'tasks', 'functions', 'extensions', 'workflows', 'views'];
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const p = path.join(dir, e.name);
  if (e.isDirectory()) return e.name.startsWith('.') || e.name === 'src' ? [] : walk(p);
  return e.name.endsWith('.json') ? [p] : [];
}).sort();
const files = ORDER.flatMap((kind) => {
  const sub = cfg.paths?.[kind];
  const dir = sub && path.join(cfg.paths.componentsRoot, sub);
  return dir && fs.existsSync(dir) ? walk(dir) : [];
}).filter((f) => !filters.length || filters.some((x) => f.includes(x)));
if (!files.length) fail('nothing to publish — no component matched.');

// A mapping that names a sibling .csx (`location`) is sent with that file's text as base64 `code`.
// Two places carry one: a script slot inside a component (mapping / rule / timer / output), and a
// sys-mappings component's OWN attributes (`{ name, location, code, encoding }`) — the helper itself.
// Missing the second published helpers with an empty `code`, and every consumer failed at run time.
// A committed `code` that differs from the file is reported: the FILE is what gets sent.
const componentsRoot = path.resolve(cfg.paths.componentsRoot);
function fillCsx(m, baseDir, stale) {
  const csx = path.resolve(baseDir, m.location);
  // `location` is data from a JSON file: never read outside the components tree.
  if (!csx.startsWith(componentsRoot + path.sep)) throw new Error(`csx outside ${cfg.paths.componentsRoot}/: ${m.location}`);
  if (!fs.existsSync(csx)) throw new Error(`csx not found: ${csx}`);
  const fresh = Buffer.from(fs.readFileSync(csx, 'utf8'), 'utf8').toString('base64');
  // A NAT (plain text) committed code is compared in the same encoding as the file.
  const committed = m.code && m.encoding === 'NAT' ? Buffer.from(m.code, 'utf8').toString('base64') : m.code;
  if (committed && committed !== fresh) stale.push(m.location);
  m.code = fresh;
  m.encoding = 'B64';
}
function inlineCsx(node, baseDir, stale) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) return node.forEach((n) => inlineCsx(n, baseDir, stale));
  if (typeof node.location === 'string' && node.location.endsWith('.csx') && 'code' in node && node.encoding !== 'REF') fillCsx(node, baseDir, stale);
  for (const key of ['mapping', 'rule', 'timer', 'output']) {
    const m = node[key];
    if (m && typeof m === 'object' && typeof m.location === 'string' && m.location.endsWith('.csx') && m.encoding !== 'REF') fillCsx(m, baseDir, stale);
  }
  for (const v of Object.values(node)) inlineCsx(v, baseDir, stale);
}

let refused = 0, sent = 0, same = 0;
const stale = [];
for (const file of files) {
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (json.domain && json.domain !== cfg.domain) fail(`${file} declares domain '${json.domain}', the workspace is '${cfg.domain}'.`);
  inlineCsx(json.attributes, path.dirname(file), stale);
  if (dry) { console.log(`· ${file} → ${json.flow}/${json.key}@${json.version}`); continue; }
  const res = await fetch(`${origin}/api/v1/definitions/publish`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(json),
  });
  const body = await res.text();
  const ok = res.status >= 200 && res.status < 300;
  const exists = res.status === 409; // this key+version is already there: a CHANGED file needs a new version
  ok ? sent++ : exists ? same++ : refused++;
  console.log(`${ok ? '✓' : exists ? '=' : '✗'} [${res.status}] ${file}${ok ? '' : exists ? ' (already published at this version)' : ' — ' + body.slice(0, 400)}`);
}
for (const loc of [...new Set(stale)]) console.warn(`⚠ committed code differs from ${loc} — the file was sent; an already-published version keeps the old script.`);
if (!dry) {
  // The runtime refreshes its post-publish caches only when told the package is complete. The
  // status is 200 either way: the body's `success` is the verdict. A runtime older than the
  // endpoint answers 404, which is said and tolerated.
  const res = await fetch(`${origin}/api/v1/definitions/publish/completed`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ domain: cfg.domain, packageName: cfg.domain }),
  });
  const text = await res.text();
  let success = res.ok;
  try { const b = JSON.parse(text); if (b && b.success === false) success = false; } catch { /* not JSON */ }
  if (res.status === 404) console.warn('⚠ publish/completed answered 404 — an older runtime; its caches refresh on restart.');
  else { console.log(`${success ? '✓' : '✗'} [${res.status}] publish/completed${success ? '' : ' — ' + text.slice(0, 300)}`); if (!success) refused++; }
}
console.log(`\n${files.length} file(s): ${dry ? 'listed' : `${sent} sent, ${same} unchanged, ${refused} refused`}.`);
process.exit(refused ? 1 : 0);
