#!/bin/sh
# check-test-coverage.sh — WARN-ONLY integration-test gates G1–G4 for a vNext domain workspace.
#
#   G1  a test project (*.csproj referencing VNext.Testing.Sdk) exists          [--build: and builds]
#   G2  every workflow key is referenced by a test file (string literal)
#   G3  heuristic: every Final state key and every target of a conditional auto
#       transition appears in a test file that references the workflow
#   G4  .claude/vnext-e2e.json stamp: failed == 0, runtimeVersion == vnext.config.json,
#       componentsHash == current components
#
# Usage: check-test-coverage.sh [--root DIR] [--workflow FILE|KEY] [--quiet] [--build] [--hash]
#   --quiet     print only WARN lines (used by the PostToolUse hook)
#   --workflow  restrict G2/G3 to one workflow (path to its JSON or its key)
#   --build     also run `dotnet build` on the test project (G1)
#   --hash      print the components hash used by G4 and exit
#
# Never blocks: always exits 0 (except 2 on bad usage). Needs node (already required for authoring).
set -u

root="."; only=""; quiet=0; build=0; hash_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --workflow) only="$2"; shift 2 ;;
    --quiet) quiet=1; shift ;;
    --build) build=1; shift ;;
    --hash) hash_only=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$root" 2>/dev/null || { echo "WARN cannot enter $root"; exit 0; }
[ -f vnext.config.json ] || { [ "$quiet" -eq 1 ] || echo "INFO no vnext.config.json in $(pwd) — not a vNext workspace"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "WARN node not found — test-coverage gates skipped"; exit 0; }

# Components hash: sha256 over "<relative path> <sha256>" of every *.json/*.csx under componentsRoot,
# sorted by path. The e2e-local skill writes the same value into .claude/vnext-e2e.json.
components_hash() {
  croot=$(node -e 'const c=require(process.argv[1]);process.stdout.write((c.paths&&c.paths.componentsRoot)||c.domain||".")' "$(pwd)/vnext.config.json")
  if command -v sha256sum >/dev/null 2>&1; then sh256='sha256sum'; else sh256='shasum -a 256'; fi
  find "$croot" -type f \( -name '*.json' -o -name '*.csx' \) -not -path '*/node_modules/*' -not -path '*/.meta/*' 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$($sh256 "$f" | cut -d' ' -f1)"; done \
    | $sh256 | cut -d' ' -f1
}

if [ "$hash_only" -eq 1 ]; then components_hash; exit 0; fi

current_hash=$(components_hash)

if [ "$build" -eq 1 ]; then
  proj=$(find . -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -not -path '*/node_modules/*' 2>/dev/null \
         | while IFS= read -r p; do grep -q 'VNext.Testing.Sdk' "$p" && echo "$p"; done | head -1)
  if [ -n "$proj" ] && command -v dotnet >/dev/null 2>&1; then
    if dotnet build "$proj" -nologo -v q >/dev/null 2>&1; then
      [ "$quiet" -eq 1 ] || echo "OK   G1 test project builds: $proj"
    else
      echo "WARN G1 test project does not build: $proj (run: dotnet build $proj)"
    fi
  fi
fi

CURRENT_HASH="$current_hash" ONLY="$only" QUIET="$quiet" node - <<'NODE'
const fs = require('fs'), path = require('path');
const quiet = process.env.QUIET === '1', only = process.env.ONLY || '';
const out = (lvl, msg) => { if (!quiet || lvl === 'WARN') console.log(`${lvl.padEnd(4)} ${msg}`); };
const cfg = JSON.parse(fs.readFileSync('vnext.config.json', 'utf8'));
const croot = (cfg.paths && cfg.paths.componentsRoot) || cfg.domain || '.';
const wdir = path.join(croot, (cfg.paths && cfg.paths.workflows) || 'Workflows');
const skip = new Set(['node_modules', 'bin', 'obj', '.git', '.meta', 'TestResults']);
function walk(dir, pred, acc = []) {
  let ents = []; try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    if (skip.has(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, pred, acc); else if (pred(p)) acc.push(p);
  }
  return acc;
}

// ---- G1: test project ------------------------------------------------------
const projects = walk('.', p => p.endsWith('.csproj'))
  .filter(p => { try { return /VNext\.Testing\.Sdk/.test(fs.readFileSync(p, 'utf8')); } catch { return false; } });
if (!projects.length) {
  out('WARN', 'G1 no integration test project (no *.csproj references VNext.Testing.Sdk) — run the integration-test skill or /vnext-ai-toolkit:vnext-init Step 7');
} else out('OK', `G1 test project: ${projects.join(', ')}`);
const testFiles = projects.flatMap(p => walk(path.dirname(p), f => f.endsWith('.cs')));
const tests = testFiles.map(f => ({ f, src: fs.readFileSync(f, 'utf8') }));
const lit = s => new RegExp('"' + s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"');

// ---- G2 / G3: workflows ----------------------------------------------------
let workflows = walk(wdir, p => p.endsWith('.json') && !p.endsWith('.diagram.json'))
  .map(f => { try { return { f, j: JSON.parse(fs.readFileSync(f, 'utf8')) }; } catch { return null; } })
  .filter(w => w && w.j && w.j.flow === 'sys-flows' && w.j.key && w.j.attributes);
if (only) workflows = workflows.filter(w => w.j.key === only || path.resolve(w.f) === path.resolve(only));
let g2 = 0, g3 = 0;
for (const { f, j } of workflows) {
  const key = j.key, a = j.attributes || {};
  const refs = tests.filter(t => lit(key).test(t.src));
  if (!refs.length) {
    g2++; out('WARN', `G2 workflow '${key}' (${f}) has no test class — integration-test skill generates one`);
    continue;
  }
  out('OK', `G2 workflow '${key}' referenced by ${refs.map(r => path.basename(r.f)).join(', ')}`);
  const src = refs.map(r => r.src).join('\n');
  const states = a.states || [];
  // Success/Error/unspecified finals must be asserted; Cancelled(7)/Timeout(8)/Terminated(3) are hints only.
  const finals = states.filter(s => String(s.stateType) === '3');
  const optional = s => ['3', '7', '8'].includes(String(s.subType)) || /cancel|timeout|timedout|terminat/i.test(s.key);
  const missingFinal = finals.filter(s => !optional(s) && !lit(s.key).test(src)).map(s => s.key);
  const missingOptional = finals.filter(s => optional(s) && !lit(s.key).test(src)).map(s => s.key);
  if (missingOptional.length) out('INFO', `G3 '${key}': cancel/timeout Final state(s) not asserted: ${missingOptional.join(', ')}`);
  const unhappy = new Set();
  const autoGroups = [...states.map(s => ({ from: s.key, tr: s.transitions || [] })), { from: '(shared)', tr: a.sharedTransitions || [] }];
  for (const g of autoGroups) {
    const conditional = g.tr.filter(t => String(t.triggerType) === '1' && String(t.triggerKind) !== '10' && t.target);
    if (conditional.length >= 2) for (const t of conditional) if (!lit(t.target).test(src)) unhappy.add(`${g.from}→${t.target}`);
  }
  if (missingFinal.length) { g3++; out('WARN', `G3 '${key}': no assertion found for Final state(s) ${missingFinal.join(', ')}`); }
  if (unhappy.size) { g3++; out('WARN', `G3 '${key}': conditional auto branch target(s) never asserted: ${[...unhappy].join(', ')} (one unhappy path per conditional pair)`); }
}
if (!workflows.length && only) out('INFO', `no workflow matches '${only}'`);

// ---- G4: e2e stamp -----------------------------------------------------------
if (!only) {
  const stampFile = path.join('.claude', 'vnext-e2e.json');
  if (!fs.existsSync(stampFile)) out('WARN', 'G4 no e2e run recorded (.claude/vnext-e2e.json) — run /vnext-ai-toolkit:e2e');
  else {
    let s = {}; try { s = JSON.parse(fs.readFileSync(stampFile, 'utf8')); } catch { }
    const problems = [];
    if (Number(s.failed) > 0) problems.push(`last run had ${s.failed} failed`);
    if (s.runtimeVersion !== cfg.runtimeVersion) problems.push(`stamp runtime ${s.runtimeVersion} ≠ vnext.config.json ${cfg.runtimeVersion}`);
    if (s.componentsHash !== process.env.CURRENT_HASH) problems.push('components changed since the last e2e run');
    if (problems.length) out('WARN', `G4 e2e stamp stale: ${problems.join('; ')} — re-run /vnext-ai-toolkit:e2e`);
    else out('OK', `G4 e2e stamp green (${s.mode || '?'} mode, ${s.passed} passed, ${s.skipped || 0} skipped, ${s.date || '?'})`);
  }
}
if (!quiet) out('INFO', `summary: ${workflows.length} workflow(s) checked, ${g2} without tests, ${g3} with coverage gaps (warn-only)`);
NODE
exit 0
