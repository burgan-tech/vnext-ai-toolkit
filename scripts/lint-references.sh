#!/bin/sh
# Lints the toolkit's knowledge files for stale runtime facts and structural drift.
# Exit 1 on any hard finding. A line may opt out with a trailing `<!-- lint:allow -->`
# (used by references/concepts/schema-runtime-gaps.md, which has to quote the stale forms).
# POSIX sh + grep/awk/sed; run from anywhere.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 2
fail=0; warn=0
red() { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
yel() { printf '\033[33mWARN\033[0m %s\n' "$*"; warn=1; }

# Files that carry knowledge (markdown + templates), excluding generated/lint-exempt ones.
knowledge() {
  find agents commands skills references templates README.md CHANGELOG.md -type f \( -name '*.md' -o -name '*.tmpl' \) 2>/dev/null \
    | grep -v 'references/runtime-feature-matrix.md' | sort
}
# grep helper: pattern, description; ignores lines with lint:allow
ban() {
  pat="$1"; desc="$2"
  hits=$(knowledge | xargs grep -nE -- "$pat" 2>/dev/null | grep -v 'lint:allow' | grep -v '^CHANGELOG.md:')
  if [ -n "$hits" ]; then red "$desc"; printf '%s\n' "$hits" | sed 's/^/     /'; fi
}

echo "== stale phrases"
ban '"1"[–-]"1[56]"|\b1[–-]1[56] task types|enum `?"?1"?[–-]"?1[56]' 'task enum ceiling stated as 15/16 (runtime 1–23, schema validates 1–21)'
ban '\| *`?5`? *\| *HumanTask|HumanTask \(type 5\)|type 5 = ?HumanTask|"5" *= *HumanTask' 'HumanTask described as task type 5 (it is a human STATE subType 6 + human-task function)'
ban 'schemas/\{componentType\}\.json|schemas/(workflow|task|view|schema|function|extension|mapping)\.json' 'wrong schema filename (real: {type}-definition.schema.json) — point to component-schemas.md'
ban 'templates/(csx-contracts|function-mapping-pattern|mocklab-seed-format|view-author-guide)\.md|AGENTS\.md\.tmpl' 'reference to a deleted templates/ duplicate'
# $CurrentUser may only appear in a denial ("no `$CurrentUser`")
hits=$(knowledge | xargs grep -n -- '\$CurrentUser' 2>/dev/null | grep -v 'lint:allow' | grep -viE 'no[* ]+`?\$CurrentUser|\$CurrentUser`? (does not|doesn.t|is not)')
[ -z "$hits" ] || { red 'mentions $CurrentUser as if it existed'; printf '%s\n' "$hits" | sed 's/^/     /'; }
ban 'schemas-snapshot/' 'mentions the non-existent schemas-snapshot folder'
ban 'zipkin' 'zipkin tracing (runtime uses otel: key → otel-collector)'
ban 'availableTransitions`? *(field|property|array)' 'state function wire field is `transitions`, not availableTransitions'
ban 'POST [^ ]*/transitions/\{' 'transition endpoint is PATCH, not POST'
ban 'filterOperators.*"(ge|le|ne|like|match)"|"enum": *\[[^]]*"(ge|le)"' 'x-filterOperators declared with WIRE operator names — schema-side names are gte/lte/neq/contains/startsWith/endsWith/isNull'

echo "== structural"
manifest=.claude-plugin/plugin.json
node -e '
const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1]));
let bad=0;
const refs=m.references||[], ws=(m.vnext&&m.vnext.workspaceReferences)||[];
for (const p of [...refs,...ws]) if(!fs.existsSync(p)){console.log("FAIL manifest path missing: "+p); bad=1;}
for (const p of ws) if(!refs.includes(p)){console.log("FAIL workspaceReferences entry not in references[]: "+p); bad=1;}
const base=new Map(); for(const p of ws){const b=p.split("/").pop(); if(base.has(b)){console.log("FAIL duplicate basename in workspaceReferences: "+b); bad=1;} base.set(b,p);}
const { execSync } = require("child_process");
const all=execSync("find references -name \"*.md\"").toString().trim().split("\n");
for (const p of all) if(!refs.includes(p)){console.log("FAIL reference file not listed in plugin.json references[]: "+p); bad=1;}
for (const k of ["knownRuntimeVersion","knownSchemaVersion"]) if(!(m.vnext&&m.vnext[k])){console.log("FAIL plugin.json vnext."+k+" missing"); bad=1;}
process.exit(bad);
' "$manifest" || fail=1

# every .claude/references/<name>.md link in knowledge files must be a workspaceReferences basename
ws_basenames=$(node -e 'const m=require(process.argv[1]); console.log(m.vnext.workspaceReferences.map(p=>p.split("/").pop()).join("\n"))' "$root/$manifest")
for f in $(knowledge); do
  for l in $(grep -oE '\.claude/references/[A-Za-z0-9._-]+\.md' "$f" 2>/dev/null | sed 's#.*/##' | sort -u); do
    printf '%s\n' "$ws_basenames" | grep -qx "$l" || red "$f links .claude/references/$l which is not in workspaceReferences"
  done
  # plugin-relative references/... links must exist
  for l in $(grep -oE '(^|[^./A-Za-z])references/(concepts/)?[A-Za-z0-9._-]+\.md' "$f" 2>/dev/null | sed -E 's/^[^r]*//' | sort -u); do
    [ -f "$l" ] || red "$f links $l which does not exist"
  done
done

echo "== feature matrix"
if [ -f references/runtime-feature-matrix.md ]; then
  known=$(sed -n 's/.*"knownRuntimeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)
  head -1 references/runtime-feature-matrix.md | grep -q "runtime ${known}," || red "runtime-feature-matrix.md header runtime version != plugin.json knownRuntimeVersion ($known)"
  grep -qE '^\| 21 \|' references/runtime-feature-matrix.md || red "runtime-feature-matrix.md task table lacks type 21"
else red "references/runtime-feature-matrix.md missing (run scripts/sync-vnext-meta.sh)"; fi

echo "== templates"
if [ -f templates/CLAUDE.md.tmpl ]; then
  # outside fenced code blocks, only allow-listed placeholders may remain
  left=$(awk '/^```/{f=!f; next} !f' templates/CLAUDE.md.tmpl | grep -oE '\{\{[^}]+\}\}' | sort -u \
        | grep -vE '^\{\{(domain|workflowKey|toolkitVersion|knownRuntimeVersion|agentFile|agentAudience|peerFile|peerAudience)\}\}$')
  [ -z "$left" ] || red "CLAUDE.md.tmpl has non-allowlisted placeholders outside code fences: $(printf '%s ' $left)"
  n=$(wc -l < templates/CLAUDE.md.tmpl); [ "$n" -le 260 ] || yel "CLAUDE.md.tmpl is $n lines (target ≤ 260)"
fi

echo "== shell syntax"
for s in hooks/*.sh scripts/*.sh; do sh -n "$s" || red "syntax error in $s"; done

if [ "$fail" -eq 0 ]; then [ "$warn" -eq 1 ] && echo "lint: OK (with warnings)" || echo "lint: OK"; exit 0; fi
echo "lint: FAILED"; exit 1
