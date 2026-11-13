#!/bin/sh
# Smoke test for skills/domain-check/scan.py: scans the fixture domain in tests/domain-check
# offline against an installed @burgan-tech/vnext-schema and asserts that every enum label
# resolved and that each measurement the fixture is built to trigger shows up.
#
# Usage: scripts/test-domain-check.sh <vnext-schema schemas dir>
#   e.g. d=$(mktemp -d); npm install --no-save --prefix "$d" @burgan-tech/vnext-schema@0.0.61
#        scripts/test-domain-check.sh "$d/node_modules/@burgan-tech/vnext-schema/schemas"
# Exit 0 = pass, 1 = assertion failed, 2 = bad usage.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
schemas=${1:-${VNEXT_SCHEMA_DIR:-}}
[ -n "$schemas" ] && [ -f "$schemas/workflow-definition.schema.json" ] || {
  echo "usage: $0 <path to vnext-schema/schemas>" >&2; exit 2; }

export PYTHONDONTWRITEBYTECODE=1
scan="$root/skills/domain-check/scan.py"
fixture="$root/tests/domain-check"
out=$(mktemp)
trap 'rm -f "$out"' EXIT

python3 "$scan" "$fixture" --schema-dir "$schemas" --no-fetch --json > "$out"

python3 - "$out" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
fail = []
def check(cond, msg):
    if not cond:
        fail.append(msg)

check(o["enumWarnings"] == [], f"enum warnings: {o['enumWarnings']}")
check(o["parseErrors"] == [], f"parse errors: {o['parseErrors']}")
check(o["schemaInstalledVersion"], "installed vnext-schema version not detected")
check(o["domain"] == "dc", "domain not read from vnext.config.json")
check("http-get-cities" in o["tasks"]["missingTimeout"], "missing timeout not reported")
check(o["cacheAside"]["keyExpression"] == ["cache-cities"], "CacheAside keyExpression not reported")
check("dapr-self-read" in o["selfCalls"], "self-domain call not reported")
check("dapr-self-read" in o["instanceScopedReads"], "instance-address read not reported")
check(o["hierarchyRefs"], "functions/hierarchy reference not reported")
check(any(c["slot"] == "calcScript" for c in o["slotCollisions"]), "same task twice at one order not reported")
check(o["executionTypeOnAutomatic"], "executionType on an automatic transition not reported")
check(o["historyNone"].get("eligible") == ["quote-calc"], f"history none candidates: {o['historyNone']}")
check([u["field"] for u in o["unindexedQueryFields"]] == ["nationalId"], "filtered field without x-indexed not reported")
check(o["computedFields"]["total"] == 1, "x-computed count wrong")
check(o["instanceScopedFunctions"] == ["fn-cities"], "instance-scope function not reported")
check(o["executionLogFunctions"] == ["fn-cities"], "executionLog E function not reported")
check(any(k.split()[0] == "0" and "?" not in k for k in o["errorBoundaryActions"]), "error action label unresolved")
check(o["extensionHotStates"], "network extension on a read surface not reported")
check(o["scriptCalls"]["serializeInLog"] == 1, "serialize-in-log not counted")
wf = {w["key"]: w for w in o["workflows"]}
check(wf.get("apply", {}).get("decisionOnlyStates") == ["checking"], "decision-only state not reported")
check(any("Get Instances" in c for c in o["unusedCapabilities"]), "unused GetInstances capability not reported")
u = o["upgrade"]
check(u["inputSchemaNoFallback"] == ["fn-rule-input"], f"rule-based inputSchema without fallback: {u['inputSchemaNoFallback']}")
check(u["transitionSchemasNoFallback"] == ["apply::draft->submit"], f"transition schemas without fallback: {u['transitionSchemasNoFallback']}")
check(len(u["fanOutItemFailedRefs"]) == 1, "FanOut:ItemFailed match in a script not reported")
check(len(u["hideFromAllPair"]) == 1, "deny+allow $InstanceStarter hide pair not reported")
check(len(u["everyoneMisplaced"]) == 1 and "x-masking" in u["everyoneMisplaced"][0], f"$Everyone in an exemption list: {u['everyoneMisplaced']}")
check(len(u["everyoneMiscased"]) == 1, "miscased $everyone not reported")
check(u["startRolesInstanceBoundOnly"] == ["apply"], "instance-bound-only startTransition.roles not reported")
base = lambda xs: sorted(x.rsplit("/", 1)[-1] for x in xs)
check(base(u["roleHeaderParsing"]) == ["ChannelRoleMapping.csx"], f"role header parsing: {u['roleHeaderParsing']}")
check(base(u["callerWhereUnavailable"]) == ["ChannelRoleMapping.csx"], f"context.Caller in a task mapping: {u['callerWhereUnavailable']}")
check(base(u["callerUnguarded"]) == ["IsApproverRule.csx"], f"unguarded context.Caller: {u['callerUnguarded']}")
check(len(u["callerUses"]) == 3, f"context.Caller uses: {u['callerUses']}")
k = o["resourceLock"]
check(len(k["lockTransitions"]) == 4, f"resourceLock transitions: {k['lockTransitions']}")
check(k["lockTtlNonPositive"] == ["limit-reserve::idle->reserve"], f"ttlSeconds <= 0: {k['lockTtlNonPositive']}")
check(k["lockRejectUses"] == ["limit-reserve::idle->reserve"], f"onConflict Reject: {k['lockRejectUses']}")
check(k["lockExtendUses"] == ["limit-reserve::shared->extend-hold"], f"Extend: {k['lockExtendUses']}")
check(k["lockRetryRules"] == ["limit-reserve::idle.onError[0]"], f"Retry on lock code: {k['lockRetryRules']}")
check(k["lockStateBoundaryUnavailable"] == ["limit-reserve::idle.onError[1] -> release"], f"state boundary target: {k['lockStateBoundaryUnavailable']}")
check(len(k["lockBoundaryTargetHasLock"]) == 2, f"boundary target with lock: {k['lockBoundaryTargetHasLock']}")
check(len(k["lockBoundaryReroutes"]) == 2, f"200010 reroutes: {k['lockBoundaryReroutes']}")
check(k["floatingRefs"] > 0, "floating component references not counted")

if fail:
    print("FAIL domain-check smoke test:")
    for f in fail:
        print("  - " + f)
    sys.exit(1)
print(f"ok domain-check smoke test (vnext-schema {o['schemaInstalledVersion']}, {len(o['workflows'])} workflows)")
EOF

# the human-readable report must not carry unresolved-enum markers either
if python3 "$scan" "$fixture" --schema-dir "$schemas" --no-fetch | grep -q '!! ENUM'; then
  echo "FAIL domain-check human output contains !! ENUM"; exit 1
fi
