#!/usr/bin/env python3
"""Static scanner for a vNext domain package (the domain-check skill).

Reads vnext.config.json, walks the component folders and prints the measurements the
domain-check skill interprets against CHECKS.md. Read-only: never writes to the target.
Standard library only.

Usage:
  python3 scan.py [root] [--config FILE] [--schema-dir DIR] [--no-fetch] [--json]

  root          domain package root; default: walk up from the current directory to the
                first folder holding the config file (exit 2 if there is none)
  --config      config file name or path (default vnext.config.json; e.g.
                vnext.credit.config.json for a multi-domain repo)
  --schema-dir  folder holding the vnext-schema *-definition.schema.json files
  --no-fetch    never download schemas (offline / CI)
  --json        machine-readable output

Enum labels (task types, trigger types, error actions, extension type/scope, function
scope, state type/subtype) are read from the domain's pinned @burgan-tech/vnext-schema at
run time. Lookup order: --schema-dir, <root>/node_modules, node_modules in parent folders,
then the plugin manifest's vnext.schemaFallbackUrl at the config's schemaVersion. A name
that cannot be resolved is printed as the raw value with a `!! ENUM:` warning.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PLUGIN_MANIFEST = os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json")
SCHEMA_PKG = os.path.join("node_modules", "@burgan-tech", "vnext-schema")
COMPONENT_TYPES = ("task", "workflow", "extension", "function", "schema")
SKIP_DIRS = (f"{os.sep}.meta{os.sep}", f"{os.sep}node_modules{os.sep}", f"{os.sep}.git{os.sep}")

ENUM_WARNINGS = []
SCHEMA_WARNINGS = []
PARSE_ERRORS = []

# ---------------------------------------------------------------------------
# Judgement sets. These are NOT enum tables: they are written as normalised label
# keys and resolved against the labels read from the pinned schema, so a renumbering
# cannot silently change what they match and a rename shows up as a warning.
# ---------------------------------------------------------------------------
# Task types whose latency belongs to a backend outside the runtime. StateStore and
# CacheAside are excluded on purpose (they are the fix for this cost), as are the
# in-process and runtime-to-runtime types.
OUTBOUND_TASKS = {"daprhttpendpoint", "daprbinding", "daprservice", "daprpubsub",
                  "http", "soap", "externalhttp", "daprconversation"}
# Runtime capabilities a domain package should be reaching for; reported when absent.
CAPABILITY_TASKS = ["getinstances", "statestore", "cacheaside", "fanout"]
TOKEN_TASK_RE = re.compile(r"token|oauth|login|auth", re.I)


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def ver(s):
    if not s:
        return None
    nums = re.findall(r"\d+", str(s))
    return tuple(int(n) for n in nums) if nums else None


def at_least(v, floor):
    """True / False when the runtime version is known, None when it is not."""
    if v is None:
        return None
    return v >= ver(floor)


def norm(label):
    """Comparable key for a schema label: lowercase alnum, trailing task/trigger/state dropped."""
    k = re.sub(r"[^a-z0-9]", "", str(label).lower())
    for suffix in ("task", "trigger", "state"):
        if k.endswith(suffix) and len(k) > len(suffix):
            k = k[: -len(suffix)]
    return k


def clean(desc):
    """'Retry (1) - Retry with ...' -> 'Retry'; 'GetInstance - The extension ...' -> 'GetInstance'."""
    s = str(desc or "").strip()
    s = re.split(r"\s+-\s+|\s+\(|\s+—\s+", s, maxsplit=1)[0].strip()
    return s


def labels(node):
    """{str(value): label} from enum+enumDescriptions, oneOf const+description, or x-enumNames."""
    if not isinstance(node, dict):
        return {}
    enum = node.get("enum")
    descs = node.get("enumDescriptions")
    if isinstance(enum, list) and isinstance(descs, list) and len(enum) == len(descs):
        return {str(v): clean(d) for v, d in zip(enum, descs)}
    one = node.get("oneOf")
    if isinstance(one, list) and one and all(isinstance(x, dict) and "const" in x for x in one):
        return {str(x["const"]): clean(x.get("description") or x.get("title") or "") for x in one}
    names = node.get("x-enumNames")
    if isinstance(enum, list) and isinstance(names, list) and len(enum) == len(names):
        return {str(v): clean(n) for v, n in zip(enum, names)}
    return {}


def node_at(doc, path):
    cur = doc
    for part in path.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def walk(o):
    """Yield every (key, value) pair in a JSON tree."""
    if isinstance(o, dict):
        for k, v in o.items():
            yield k, v
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


def camel(key):
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", key or "") if p]
    return (parts[0][:1].lower() + parts[0][1:] + "".join(p[:1].upper() + p[1:] for p in parts[1:])) if parts else ""


# ---------------------------------------------------------------------------
# root / config / schema discovery
# ---------------------------------------------------------------------------
def find_root(root_arg, config_arg):
    name = config_arg or "vnext.config.json"
    if config_arg and (os.path.isabs(config_arg) or os.path.isfile(config_arg)) and not root_arg:
        p = os.path.abspath(config_arg)
        if os.path.isfile(p):
            return os.path.dirname(p), p
    start = os.path.abspath(root_arg or os.getcwd())
    if os.path.isfile(start):
        start = os.path.dirname(start)
    cur = start
    while True:
        cand = os.path.join(cur, os.path.basename(name) if not os.path.isabs(name) else name)
        if os.path.isfile(cand):
            return cur, cand
        parent = os.path.dirname(cur)
        if parent == cur:
            return None, None
        cur = parent


def read_manifest():
    try:
        with open(PLUGIN_MANIFEST, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def pkg_version(schemas_dir):
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(schemas_dir)), "package.json"),
                  encoding="utf-8") as fh:
            pj = json.load(fh)
        return pj.get("version") if pj.get("name") == "@burgan-tech/vnext-schema" else None
    except (OSError, ValueError):
        return None


def load_schemas(root, schema_dir, no_fetch, schema_version, manifest):
    """-> (schemas{type: doc}, source label, installed version or None)."""
    candidates = []
    if schema_dir:
        candidates.append(("--schema-dir", schema_dir))
    candidates.append(("node_modules", os.path.join(root, SCHEMA_PKG, "schemas")))
    cur = os.path.dirname(root)
    while True:
        candidates.append(("ust klasor node_modules", os.path.join(cur, SCHEMA_PKG, "schemas")))
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    for label, d in candidates:
        if not os.path.isfile(os.path.join(d, "workflow-definition.schema.json")):
            if label == "--schema-dir":
                SCHEMA_WARNINGS.append(f"--schema-dir icinde workflow-definition.schema.json yok: {d}")
            continue
        out = {}
        for t in COMPONENT_TYPES:
            p = os.path.join(d, f"{t}-definition.schema.json")
            try:
                with open(p, encoding="utf-8") as fh:
                    out[t] = json.load(fh)
            except (OSError, ValueError) as e:
                SCHEMA_WARNINGS.append(f"okunamadi: {p} ({e.__class__.__name__})")
        return out, f"{label}: {os.path.abspath(d)}", pkg_version(d)

    tmpl = (manifest.get("vnext") or {}).get("schemaFallbackUrl")
    if no_fetch:
        SCHEMA_WARNINGS.append("yerel vnext-schema bulunamadi ve --no-fetch verildi")
        return {}, "yok", None
    if not tmpl:
        SCHEMA_WARNINGS.append("yerel vnext-schema yok; plugin.json vnext.schemaFallbackUrl okunamadi")
        return {}, "yok", None
    if not schema_version:
        SCHEMA_WARNINGS.append("yerel vnext-schema yok ve config'te schemaVersion yok; indirilemez")
        return {}, "yok", None
    out = {}
    for t in COMPONENT_TYPES:
        url = tmpl.replace("{schemaVersion}", str(schema_version)).replace("{componentType}", t)
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                out[t] = json.loads(r.read().decode("utf-8"))
        except Exception as e:  # network errors of every flavour
            SCHEMA_WARNINGS.append(f"indirilemedi: {url} ({e.__class__.__name__})")
    if not out:
        return {}, "yok", None
    return out, f"indirildi: {tmpl.replace('{schemaVersion}', str(schema_version))}", str(schema_version)


class Enums:
    """Enum labels resolved from the loaded schemas; nothing is hardcoded."""

    SOURCES = {
        "TaskType": ("task", "properties.attributes.properties.type"),
        "TriggerType": ("workflow", "definitions.triggerType"),
        "ErrorAction": ("workflow", "definitions.errorAction"),
        "StateType": ("workflow", "definitions.stateType"),
        "StateSubType": ("workflow", "definitions.stateSubType"),
        "ExtensionType": ("extension", "properties.attributes.properties.type"),
        "ExtensionScope": ("extension", "properties.attributes.properties.scope"),
        "FunctionScope": ("function", "properties.attributes.properties.scope"),
    }

    def __init__(self, schemas):
        self.map = {}
        for name, (ctype, path) in self.SOURCES.items():
            lab = labels(node_at(schemas.get(ctype) or {}, path))
            if not lab:
                ENUM_WARNINGS.append(f"{name} çözülemedi ({ctype}-definition.schema.json#{path})")
            self.map[name] = lab
        self._seen_unknown = set()

    def label(self, name, value):
        if value is None:
            return None
        lab = self.map.get(name) or {}
        v = str(value)
        if v in lab:
            return lab[v]
        if lab and (name, v) not in self._seen_unknown:
            self._seen_unknown.add((name, v))
            ENUM_WARNINGS.append(f"{name} degeri {v!r} pinlenen semada yok")
        return "?"

    def key(self, name, value):
        lbl = self.label(name, value)
        return norm(lbl) if lbl and lbl != "?" else None

    def codes(self, name, *keys):
        """Values whose normalised label is (or, with a leading '~', contains) one of keys."""
        out = set()
        for v, lbl in (self.map.get(name) or {}).items():
            k = norm(lbl)
            for want in keys:
                if (want.startswith("~") and want[1:] in k) or k == want:
                    out.add(v)
        return out

    def require(self, name, *keys):
        vals = self.codes(name, *keys)
        if self.map.get(name) and not vals:
            ENUM_WARNINGS.append(f"{name} icinde bulunamayan etiket: {', '.join(keys)}")
        return vals


# ---------------------------------------------------------------------------
# component loading
# ---------------------------------------------------------------------------
TEXT = {}


def read_text(p):
    if p not in TEXT:
        try:
            with open(p, encoding="utf-8-sig") as fh:
                TEXT[p] = fh.read()
        except OSError:
            TEXT[p] = ""
    return TEXT[p]


def load_json(p):
    try:
        return json.loads(read_text(p))
    except ValueError as e:
        PARSE_ERRORS.append(f"{p}: {e.__class__.__name__}")
        return None


def skip(p):
    return any(s in p for s in SKIP_DIRS)


def files(base, pattern):
    return sorted(f for f in glob.glob(os.path.join(base, "**", pattern), recursive=True) if not skip(f))


def components(croot, sub):
    out = []
    for f in files(os.path.join(croot, sub), "*.json"):
        d = load_json(f)
        if isinstance(d, dict) and d.get("key") and isinstance(d.get("attributes"), dict):
            out.append((f, d))
    return out


def ref_key(ref, by_stem):
    """Task/workflow key from an explicit reference or a {ref: path} reference."""
    if not isinstance(ref, dict):
        return None
    if ref.get("key"):
        return ref["key"]
    r = ref.get("ref")
    if r:
        stem = os.path.splitext(os.path.basename(r))[0]
        return by_stem.get(stem, stem)
    return None


def state_views(state):
    v = state.get("view")
    out = [v] if isinstance(v, dict) else []
    out += [x for x in (state.get("views") or []) if isinstance(x, dict)]
    return out


def view_extensions(views):
    names = []
    for v in views:
        for k, val in walk(v):
            if k == "extensions" and isinstance(val, list):
                names += [x for x in val if isinstance(x, str)]
    return names


def transitions_of(attrs):
    """(origin, transition) for every transition a workflow defines."""
    for s in attrs.get("states") or []:
        for t in s.get("transitions") or []:
            yield s.get("key"), t
    for t in attrs.get("sharedTransitions") or []:
        yield "shared", t
    for name in ("startTransition", "cancel", "exit", "updateData"):
        t = attrs.get(name)
        if isinstance(t, dict):
            yield name, t


def hooks_of(attrs):
    """(state, hook, [entries]) for every task list a workflow defines."""
    for s in attrs.get("states") or []:
        for h in ("onEntries", "onExits", "onExecutionTasks"):
            if s.get(h):
                yield s.get("key"), h, s.get(h)
        for t in s.get("transitions") or []:
            if t.get("onExecutionTasks"):
                yield s.get("key"), f"transition:{t.get('key')}", t["onExecutionTasks"]
    for origin, t in transitions_of({k: v for k, v in attrs.items() if k != "states"}):
        if t.get("onExecutionTasks"):
            yield origin, f"transition:{t.get('key')}", t["onExecutionTasks"]


# ---------------------------------------------------------------------------
# the scan
# ---------------------------------------------------------------------------
def scan(root, cfg_path, schema_dir, no_fetch):
    manifest = read_manifest()
    mv = manifest.get("vnext") or {}
    cfg = load_json(cfg_path) or {}
    paths = cfg.get("paths") or {}
    croot = os.path.join(root, paths.get("componentsRoot", "."))
    rt = ver(cfg.get("runtimeVersion"))
    schemas, source, installed = load_schemas(root, schema_dir, no_fetch, cfg.get("schemaVersion"), manifest)
    if installed and cfg.get("schemaVersion") and installed != str(cfg.get("schemaVersion")):
        SCHEMA_WARNINGS.append(f"kurulu vnext-schema {installed} != config schemaVersion {cfg.get('schemaVersion')}"
                               " — etiketler kurulu paketten okundu")
    E = Enums(schemas)
    AUTO = E.require("TriggerType", "automatic")
    EVENT = E.require("TriggerType", "event")
    FINAL = E.require("StateType", "final")
    WIZARD = E.require("StateType", "wizard")
    BLOCKING_SUB = E.require("StateSubType", "~suspended", "busy", "human")
    INSTANCE_SCOPE = E.require("FunctionScope", "instance")
    GLOBAL_EXT = E.codes("ExtensionType", "global", "globalandrequested")
    RETRY = E.require("ErrorAction", "retry")
    outbound_found = {norm(l) for l in (E.map.get("TaskType") or {}).values()}
    if E.map.get("TaskType"):
        missing = sorted(OUTBOUND_TASKS - outbound_found)
        if missing:
            ENUM_WARNINGS.append(f"TaskType icinde bulunamayan etiket: {missing} — dis cagri kumesi eksik eslesir")

    def is_auto(t):
        return str(t.get("triggerType")) in AUTO

    # task types whose config schema carries timeoutSeconds (derived, not listed)
    timeout_capable = set()
    for br in node_at(schemas.get("task") or {}, "properties.attributes.allOf") or []:
        ty = node_at(br, "if.properties.type") or {}
        vals = [ty["const"]] if "const" in ty else (ty.get("enum") or [])
        if "timeoutSeconds" in (node_at(br, "then.properties.config.properties") or {}):
            timeout_capable |= {str(v) for v in vals}

    gates = {"runtime": cfg.get("runtimeVersion"),
             "ge_0_0_94": at_least(rt, "0.0.94"), "ge_0_0_99": at_least(rt, "0.0.99"),
             "ge_0_0_100": at_least(rt, "0.0.100")}
    out = {
        "root": root, "config": os.path.relpath(cfg_path, root),
        "domain": cfg.get("domain"),
        "runtimeVersion": cfg.get("runtimeVersion"), "schemaVersion": cfg.get("schemaVersion"),
        "toolkitKnownRuntimeVersion": mv.get("knownRuntimeVersion"),
        "toolkitKnownSchemaVersion": mv.get("knownSchemaVersion"),
        "schemaSource": source, "schemaInstalledVersion": installed,
        "gates": gates,
    }

    # ---- tasks -------------------------------------------------------------
    task_comps = components(croot, paths.get("tasks", "Tasks"))
    by_stem = {os.path.splitext(os.path.basename(f))[0]: d["key"] for f, d in task_comps}
    tasks, ttypes, notimeout = {}, collections.Counter(), []
    signatures = collections.defaultdict(list)
    cache_kx = []
    for f, d in task_comps:
        a = d["attributes"]
        t = str(a.get("type"))
        c = a.get("config") if isinstance(a.get("config"), dict) else {}
        k = E.key("TaskType", t)
        url = c.get("url") or c.get("methodName") or c.get("path") or ""
        tasks[d["key"]] = {"type": t, "label": E.label("TaskType", t), "norm": k, "file": f,
                           "timeout": c.get("timeoutSeconds"), "url": url,
                           "outbound": k in OUTBOUND_TASKS}
        ttypes[f"{t} {E.label('TaskType', t)}"] += 1
        if c:
            signatures[(t, json.dumps(c, sort_keys=True, ensure_ascii=False))].append(d["key"])
        if k in OUTBOUND_TASKS and t in timeout_capable and c.get("timeoutSeconds") is None:
            notimeout.append(d["key"])
        if k == "cacheaside" and "keyExpression" in c:
            cache_kx.append(d["key"])
    out["tasks"] = {"total": len(tasks), "byType": dict(ttypes), "missingTimeout": sorted(notimeout),
                    "timeoutCapableTypes": sorted(timeout_capable, key=lambda x: int(x) if x.isdigit() else 0)}
    out["duplicateTasks"] = sorted((sorted(v) for v in signatures.values() if len(v) > 1), key=lambda g: g[0])
    present = {v["norm"] for v in tasks.values()}
    out["unusedCapabilities"] = [f"{v} {lbl}" for v, lbl in sorted((E.map.get("TaskType") or {}).items(),
                                                                   key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)
                                 if norm(lbl) in CAPABILITY_TASKS and norm(lbl) not in present]
    out["cacheAside"] = {"count": sum(1 for v in tasks.values() if v["norm"] == "cacheaside"),
                         "keyExpression": sorted(cache_kx)}
    dom = cfg.get("domain")
    out["selfCalls"] = sorted(k for k, v in tasks.items() if v["outbound"] and dom and f"/{dom}/" in v["url"])
    out["instanceScopedReads"] = sorted(k for k, v in tasks.items()
                                        if re.search(r"/instances/[^/?]+/functions/", v["url"]))

    # ---- workflows ---------------------------------------------------------
    wf_comps = components(croot, paths.get("workflows", "Workflows"))
    wf_by_stem = {os.path.splitext(os.path.basename(f))[0]: d["key"] for f, d in wf_comps}
    wfs, subedges, eb = [], [], collections.Counter()
    slot_collisions, tmpl = [], collections.Counter()
    token_use = collections.Counter()
    exec_auto = []
    for f, d in wf_comps:
        a = d["attributes"]
        states = [s for s in (a.get("states") or []) if isinstance(s, dict)]
        tt = collections.Counter()
        exec_trans = collections.Counter()
        for origin, tr in transitions_of(a):
            lbl = E.label("TriggerType", tr.get("triggerType"))
            tt[norm(lbl) if lbl and lbl != "?" else f"?{tr.get('triggerType')}"] += 1
            if tr.get("executionType"):
                exec_trans[tr["executionType"]] += 1
                if is_auto(tr):
                    exec_auto.append(f"{d['key']}::{origin}->{tr.get('key')}")
        decision, multihook, cumulative, nettouch = [], {}, 0, 0
        for s in states:
            trs = s.get("transitions") or []
            sf = s.get("subFlow") if isinstance(s.get("subFlow"), dict) else None
            if sf:
                subedges.append((d["key"], s.get("key"), ref_key(sf.get("process"), wf_by_stem), sf.get("type")))
            has_hooks = any(s.get(h) for h in ("onEntries", "onExits", "onExecutionTasks")) or \
                any(t.get("onExecutionTasks") for t in trs)
            if not state_views(s) and not has_hooks and not sf and trs and all(is_auto(t) for t in trs):
                decision.append(s.get("key"))
            tmpl[(s.get("stateType"), s.get("subType"), len(trs),
                  tuple(sorted(ref_key(e.get("task"), by_stem) or "" for h in ("onEntries", "onExits")
                               for e in (s.get(h) or []))), bool(state_views(s)))] += 1
        for origin, hook, entries in hooks_of(a):
            lst, slots = [], collections.defaultdict(list)
            for e in entries:
                if not isinstance(e, dict):
                    continue
                tk = ref_key(e.get("task"), by_stem)
                lst.append((e.get("order"), tk))
                slots[(e.get("order"), e.get("variableKey") or camel(tk))].append(tk)
                info = tasks.get(tk)
                if info and info["outbound"]:
                    nettouch += 1
                    cumulative += info["timeout"] or 0
                if tk and TOKEN_TASK_RE.search(tk):
                    token_use[tk] += 1
            for (order, slot), tks in slots.items():
                if len(tks) > 1:
                    slot_collisions.append({"where": f"{d['key']}::{origin}::{hook}", "order": order,
                                            "slot": slot, "tasks": tks})
            if len(lst) >= 2:
                multihook[f"{origin}::{hook}"] = lst
        # error boundary actions anywhere in the definition
        has_eb = False
        for k, v in walk(a):
            if k == "errorBoundary" and isinstance(v, dict):
                for rule in v.get("onError") or []:
                    if isinstance(rule, dict) and "action" in rule:
                        eb[str(rule["action"])] += 1
                        has_eb = True
        txt = read_text(f)
        wfs.append({
            "key": d["key"], "type": a.get("type"), "file": f, "states": len(states),
            "transitions": sum(tt.values()), "trigger": dict(tt),
            "executionType": a.get("executionType"), "transitionExecutionType": dict(exec_trans),
            "history": a.get("history"),
            "decisionOnlyStates": decision, "multiTaskHooks": multihook,
            "networkCalls": nettouch, "cumulativeTimeoutSeconds": cumulative,
            "longestAutoChain": longest_auto_chain(states, is_auto), "hasTimeout": bool(a.get("timeout")),
            "selfTargets": len(re.findall(r'"target"\s*:\s*"\$self"', txt)),
            "loadData": len(re.findall(r'"loadData"\s*:\s*true', txt)),
            "signature": sorted(s.get("key") or "" for s in states),
            "hasErrorBoundary": has_eb,
            "functionCacheTtl": node_at(a, "config.functionCache.ttlSeconds"),
            "schema": ref_key(a.get("schema"), {}) if isinstance(a.get("schema"), dict) else None,
            "_attrs": a,
        })
    wf_index = {w["key"]: w for w in wfs}
    out["subflowEdges"] = subedges
    out["subflowTypes"] = dict(collections.Counter(str(e[3]) for e in subedges))
    out["missingSubflowTargets"] = sorted({e[2] for e in subedges if e[2]} - set(wf_index))
    out["errorBoundaryActions"] = {f"{k} {E.label('ErrorAction', k)}": v
                                   for k, v in sorted(eb.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)}
    out["retryUsed"] = sum(v for k, v in eb.items() if k in RETRY)
    out["workflowsWithoutErrorBoundary"] = sorted(w["key"] for w in wfs if not w["hasErrorBoundary"])
    event_keys = {norm(E.map["TriggerType"][c]) for c in EVENT}
    out["eventTransitions"] = sum(n for w in wfs for k, n in w["trigger"].items() if k in event_keys)
    out["selfTargets"] = sum(w["selfTargets"] for w in wfs)
    out["loadDataTotal"] = sum(w["loadData"] for w in wfs)
    out["slotCollisions"] = slot_collisions
    out["executionTypeOnAutomatic"] = exec_auto
    out["executionTypeUsed"] = sorted(w["key"] for w in wfs if w["executionType"] or w["transitionExecutionType"])
    out["tokenTaskHooks"] = dict(token_use)
    bysig = collections.defaultdict(list)
    for w in wfs:
        if len(w["signature"]) > 1:
            bysig[tuple(w["signature"])].append(w["key"])
    out["duplicateWorkflows"] = [v for v in bysig.values() if len(v) > 1]
    out["stateTemplates"] = [{"count": c, "stateType": k[0], "subType": k[1], "transitions": k[2],
                              "tasks": [x for x in k[3] if x]} for k, c in tmpl.most_common(5) if c >= 3]

    # ---- check 20: history none eligibility --------------------------------
    hist = {"eligible": [], "alreadyNone": [], "noneButIneligible": {}, "reasons": {}, "withChild": {}}
    if not (AUTO and FINAL):
        hist["skipped"] = "TriggerType/StateType etiketleri cozulemedi"
    else:
        memo = {}

        def eligibility(w, stack=()):
            if w["key"] in memo:
                return memo[w["key"]]
            a, why = w["_attrs"], []
            for fld in ("timeout", "cancel", "exit", "updateData"):
                if a.get(fld):
                    why.append(fld)
            if a.get("sharedTransitions"):
                why.append("sharedTransitions")
            states = [s for s in (a.get("states") or []) if isinstance(s, dict)]
            finals = {s.get("key") for s in states if str(s.get("stateType")) in FINAL}
            if not finals:
                why.append("Finish state yok")
            graph = {}
            for s in states:
                if str(s.get("stateType")) in WIZARD:
                    why.append(f"wizard state {s.get('key')}")
                if str(s.get("subType")) in BLOCKING_SUB:
                    why.append(f"subType {E.label('StateSubType', s.get('subType'))} ({s.get('key')})")
                if node_at(s, "interaction.longPoll"):
                    why.append(f"longPoll ({s.get('key')})")
                trs = s.get("transitions") or []
                if any(not is_auto(t) for t in trs):
                    why.append(f"otomatik olmayan transition ({s.get('key')})")
                if s.get("key") not in finals and not trs:
                    why.append(f"cikissiz state ({s.get('key')})")
                graph[s.get("key")] = {t.get("target") for t in trs if t.get("target") not in (None, "$self")}
                sf = s.get("subFlow") if isinstance(s.get("subFlow"), dict) else None
                if sf:
                    if node_at(sf, "overrides.timeout"):
                        why.append(f"subFlow timeout override ({s.get('key')})")
                    child = ref_key(sf.get("process"), wf_by_stem)
                    cw = wf_index.get(child)
                    if str(sf.get("type")) == "S":
                        # a 'none' parent's S child must itself be 'none' (checked at start)
                        if cw is None:
                            why.append(f"S child {child} domain disi, kontrol edilemedi")
                        elif cw["history"] != "none":
                            if w["history"] == "none":
                                why.append(f"S child {child} history none degil")
                            elif child in stack or not eligibility(cw, stack + (w["key"],))[0]:
                                why.append(f"S child {child} none olamaz")
                            else:
                                hist["withChild"].setdefault(w["key"], []).append(child)
            # every non-final state must reach a final one
            reach = set(finals)
            changed = True
            while changed:
                changed = False
                for k, tg in graph.items():
                    if k not in reach and tg & reach:
                        reach.add(k)
                        changed = True
            stuck = sorted(k for k in graph if k not in reach)
            if finals and stuck:
                why.append(f"Finish'e ulasamayan state: {', '.join(map(str, stuck[:5]))}")
            res = (not why, why)
            memo[w["key"]] = res
            return res

        for w in wfs:
            ok, why = eligibility(w)
            if w["history"] == "none":
                hist["alreadyNone"].append(w["key"])
                if not ok:
                    hist["noneButIneligible"][w["key"]] = why
            elif ok:
                hist["eligible"].append(w["key"])
            else:
                hist["reasons"][w["key"]] = why[:4]
    out["historyNone"] = hist

    # ---- extensions --------------------------------------------------------
    exts = []
    for f, d in components(croot, paths.get("extensions", "Extensions")):
        a = d["attributes"]
        tk = ref_key(node_at(a, "task.task"), by_stem) or ref_key(a.get("task"), by_stem)
        info = tasks.get(tk) or {}
        exts.append({"key": d["key"], "type": E.label("ExtensionType", a.get("type")),
                     "scope": E.label("ExtensionScope", a.get("scope")),
                     "global": str(a.get("type")) in GLOBAL_EXT, "task": tk,
                     "taskType": info.get("label"), "network": bool(info.get("outbound"))})
    out["extensions"] = exts
    ext_net = {e["key"] for e in exts if e["network"]}
    perstate, attach = [], collections.Counter()
    for w in wfs:
        for s in w["_attrs"].get("states") or []:
            if not isinstance(s, dict):
                continue
            views = state_views(s)
            names = set(view_extensions(views))
            for n in names:
                attach[n] += 1
            netset = sorted(names & ext_net)
            if netset:
                perstate.append({"workflow": w["key"], "state": s.get("key"), "views": len(views),
                                 "networkExtensions": netset, "callsPerRead": len(netset)})
    out["extensionAttachments"] = dict(attach)
    out["extensionHotStates"] = perstate
    out["globalNetworkExtensions"] = sorted(e["key"] for e in exts if e["global"] and e["network"])

    # ---- functions ---------------------------------------------------------
    fns = []
    for f, d in components(croot, paths.get("functions", "Functions")):
        a = d["attributes"]
        entries = []
        if isinstance(a.get("task"), dict):
            entries.append(a["task"])
        entries += [e for e in (a.get("onExecutionTasks") or []) if isinstance(e, dict)]
        tks = [ref_key(e.get("task"), by_stem) for e in entries]
        slots = collections.Counter(e.get("variableKey") or camel(tk) for e, tk in zip(entries, tks))
        for slot, n in slots.items():
            if n > 1:
                slot_collisions.append({"where": f"function:{d['key']}", "order": "*", "slot": slot,
                                        "tasks": [tk for e, tk in zip(entries, tks)
                                                  if (e.get("variableKey") or camel(tk)) == slot]})
        fns.append({"key": d["key"], "scope": a.get("scope"), "scopeLabel": E.label("FunctionScope", a.get("scope")),
                    "tasks": tks, "taskTypes": [(tasks.get(tk) or {}).get("label") for tk in tks],
                    "executionLog": a.get("executionLog"), "cache": bool(a.get("cache")),
                    "cacheKeyExpression": bool(node_at(a, "cache.keyExpression"))})
    out["functions"] = fns
    out["instanceScopedFunctions"] = sorted(fn["key"] for fn in fns if str(fn["scope"]) in INSTANCE_SCOPE)
    out["executionLogFunctions"] = sorted(fn["key"] for fn in fns if fn["executionLog"] == "E")
    out["cachedFunctions"] = sorted(fn["key"] for fn in fns if fn["cache"])
    out["workflowFunctionCache"] = {w["key"]: w["functionCacheTtl"] for w in wfs if w["functionCacheTtl"] is not None}

    # ---- schemas: binding, x-indexed, x-computed --------------------------
    sch_comps = components(croot, paths.get("schemas", "Schemas"))
    bound_master = {w["schema"] for w in wfs if w["schema"]}
    unindexed, computed, computed_server, indexed = [], collections.Counter(), [], 0
    for f, d in sch_comps:
        a = d["attributes"]
        is_master = a.get("type") == "master" or d["key"] in bound_master
        if not is_master:
            continue
        for path, prop in schema_props(a.get("schema") or {}):
            if not isinstance(prop, dict):
                continue
            if "x-computed" in prop:
                computed[d["key"]] += 1
                if node_at(prop, "x-computed.evaluatedBy") == "server":
                    computed_server.append(f"{d['key']}:{path}")
            if prop.get("x-indexed") is True:
                indexed += 1
            queried = prop.get("x-filterOperators") or prop.get("x-sortable") is True
            scalar = prop.get("type") in ("string", "number", "integer", "boolean") or \
                (isinstance(prop.get("type"), list) and set(prop["type"]) - {"null"} <= {"string", "number", "integer", "boolean"})
            if queried and scalar and prop.get("x-indexed") is not True:
                unindexed.append({"schema": d["key"], "field": path,
                                  "filter": bool(prop.get("x-filterOperators")), "sort": prop.get("x-sortable") is True,
                                  "masterType": a.get("type")})
    out["unindexedQueryFields"] = unindexed
    out["indexedFields"] = indexed
    out["computedFields"] = {"total": sum(computed.values()), "bySchema": dict(computed),
                             "evaluatedByServer": computed_server}
    bound = nulls = 0
    for w in wfs:
        for _, tr in transitions_of(w["_attrs"]):
            if "schema" in tr:
                if isinstance(tr["schema"], dict):
                    bound += 1
                elif tr["schema"] is None:
                    nulls += 1
    out["schemaBinding"] = {"bound": bound, "null": nulls}

    # ---- orphans -----------------------------------------------------------
    all_json = files(croot, "*.json")
    csx_files = files(croot, "*.csx")
    for label, sub in (("views", paths.get("views", "Views")), ("schemas", paths.get("schemas", "Schemas")),
                       ("tasks", paths.get("tasks", "Tasks"))):
        defined = {d["key"]: f for f, d in components(croot, sub)}
        folder = os.path.join(croot, sub) + os.sep
        others = " ".join(read_text(f) for f in all_json + csx_files if not f.startswith(folder))
        # a task referenced only by another task (CacheAside sourceTask, FanOut task) still counts
        if label == "tasks":
            others += " ".join(read_text(f) for f in defined.values())
        out[f"{label}Orphans"] = {"defined": len(defined),
                                  "unreferenced": sorted(k for k, f in defined.items()
                                                         if others.count(f'"{k}"') - (1 if label == "tasks" else 0) <= 0
                                                         and os.path.splitext(os.path.basename(f))[0] + ".json" not in others)}

    # ---- scripts -----------------------------------------------------------
    cs = sorted(((os.path.getsize(f), f) for f in csx_files), reverse=True)
    out["scripts"] = {"count": len(cs), "totalKB": round(sum(s for s, _ in cs) / 1024, 1),
                      "largest": [{"bytes": s, "file": f} for s, f in cs[:10]]}
    csx_text = "\n".join(read_text(f) for _, f in cs)
    task_text = " ".join(read_text(v["file"]) for v in tasks.values())
    out["scriptCalls"] = {
        "GetSecret": len(re.findall(r"\bGetSecrets?(?:Async)?\s*\(", csx_text)),
        "GetConfigValue": len(re.findall(r"\bGetConfigValue\s*\(", csx_text)),
        "contextRelated": len(re.findall(r"\bcontext\.Related\b", csx_text)),
        "InstanceQueryFluent": len(re.findall(r"\bInstanceQuery\b", csx_text)),
        "handBuiltFilterJson": len(re.findall(r"JsonSerializer\.Serialize", csx_text)),
        "serializeInLog": len(re.findall(r"\bLog(?:Information|Warning|Error|Debug|Critical|Trace)\s*\([^;]*?"
                                         r"JsonSerializer\.Serialize", csx_text)),
    }
    out["filterPaths"] = sorted(set(re.findall(r"attributes\.[A-Za-z0-9_.]+", csx_text + task_text)))
    hier = []
    for f in all_json + csx_files:
        if re.search(r"functions/hierarchy\b", read_text(f)):
            hier.append(os.path.relpath(f, root))
    out["hierarchyRefs"] = hier

    vfiles = sorted(((os.path.getsize(f), f) for f, _ in components(croot, paths.get("views", "Views"))), reverse=True)
    out["heaviestViews"] = [{"bytes": b, "file": f} for b, f in vfiles[:5]]
    total, blobs, seen = 0, 0, collections.Counter()
    for f in all_json:
        s = read_text(f)
        total += len(s)
        for m in re.finditer(r'"code"\s*:\s*"([^"]{200,})"', s):
            blobs += 1
            seen[m.group(1)] += 1
    code = sum(len(k) * v for k, v in seen.items())
    out["embeddedCode"] = {"jsonBytes": total, "codeBytes": code,
                           "sharePct": round(code * 100 / total, 1) if total else 0,
                           "blobs": blobs, "distinct": len(seen),
                           "duplicateBytes": sum((v - 1) * len(k) for k, v in seen.items() if v > 1),
                           "maxRepeat": max(seen.values()) if seen else 0}

    out["workflows"] = [{k: v for k, v in w.items() if k not in ("_attrs", "signature")} for w in wfs]
    out["enumWarnings"] = ENUM_WARNINGS
    out["schemaWarnings"] = SCHEMA_WARNINGS
    out["parseErrors"] = PARSE_ERRORS
    return out


def schema_props(schema, prefix=""):
    """(dotted path, property schema) for every nested property of a JSON schema."""
    props = schema.get("properties") if isinstance(schema, dict) else None
    if not isinstance(props, dict):
        return
    for name, p in props.items():
        path = f"{prefix}{name}"
        yield path, p
        if isinstance(p, dict):
            yield from schema_props(p, path + ".")


def longest_auto_chain(states, is_auto, budget=200000):
    g = {s.get("key"): [t.get("target") for t in (s.get("transitions") or [])
                        if is_auto(t) and t.get("target") not in (None, "$self")] for s in states}
    best, steps = [], [0]

    def go(n, path, seen):
        nonlocal best
        steps[0] += 1
        if steps[0] > budget:
            return
        if len(path) > len(best):
            best = list(path)
        for m in g.get(n, []):
            if m not in seen:
                go(m, path + [m], seen | {m})

    for s in states:
        go(s.get("key"), [s.get("key")], {s.get("key")})
    return best


# ---------------------------------------------------------------------------
# human output
# ---------------------------------------------------------------------------
def human(o):
    p = print
    g = o["gates"]

    def gate(flag, floor):
        return "" if flag else (f" [runtime {floor}+ gerekir]" if flag is False else f" [runtime {floor}+; surum bilinmiyor]")

    p(f"# domain: {o['domain']}  runtime: {o['runtimeVersion']}  schema: {o['schemaVersion']}"
      f"   (toolkit bilinen: runtime {o['toolkitKnownRuntimeVersion']} / schema {o['toolkitKnownSchemaVersion']})")
    p(f"  config: {o['config']}   kok: {o['root']}")
    p(f"  sema kaynagi: {o['schemaSource']}   kurulu vnext-schema: {o['schemaInstalledVersion'] or '?'}")
    for w in o["schemaWarnings"]:
        p(f"  !! SCHEMA: {w}")
    for w in o["enumWarnings"]:
        p(f"  !! ENUM: {w}")
    for w in o["parseErrors"][:10]:
        p(f"  !! JSON: {w}")
    p("")
    p("## tasks")
    p(f"  total {o['tasks']['total']}  " + ", ".join(f"{k}={v}" for k, v in sorted(o['tasks']['byType'].items(),
                                                                                    key=lambda kv: int(kv[0].split()[0]) if kv[0].split()[0].isdigit() else 0)))
    if o["tasks"]["missingTimeout"]:
        p(f"  !! timeout YOK ({len(o['tasks']['missingTimeout'])}): {', '.join(o['tasks']['missingTimeout'])}")
    if o["unusedCapabilities"]:
        p(f"  hic kullanilmayan yetenek: {', '.join(o['unusedCapabilities'])}")
    ca = o["cacheAside"]
    if ca["keyExpression"]:
        tag = "KIRIK (0.0.99'da kaldirildi)" if g["ge_0_0_99"] else "0.0.99'a geciste kirilir"
        p(f"  !! CacheAside keyExpression ({len(ca['keyExpression'])}) — {tag}: {', '.join(ca['keyExpression'])}")
    if o["selfCalls"]:
        p(f"  !! kendi domainine cagri ({len(o['selfCalls'])}): {', '.join(o['selfCalls'])}")
    if o["instanceScopedReads"]:
        p(f"  !! instance adresinden okuma ({len(o['instanceScopedReads'])}): {', '.join(o['instanceScopedReads'])}")
    for grp in o["duplicateTasks"]:
        p(f"  !! ikiz task tanimi: {', '.join(grp)}")
    if o["tokenTaskHooks"]:
        p("  token task kullanimi: " + ", ".join(f"{k} x{v} hook" for k, v in sorted(o["tokenTaskHooks"].items())))
    p("")
    p("## workflows")
    for w in o["workflows"]:
        ex = w["executionType"] or "-"
        p(f"  {w['key']:40} {w['type']} states={w['states']:3} trans={w['transitions']:3} {w['trigger']} "
          f"net={w['networkCalls']} cumTimeout={w['cumulativeTimeoutSeconds']}s chain={len(w['longestAutoChain'])} "
          f"decision={len(w['decisionOnlyStates'])} timeout={'var' if w['hasTimeout'] else 'yok'} "
          f"exec={ex}{('/' + str(w['transitionExecutionType'])) if w['transitionExecutionType'] else ''} "
          f"history={w['history'] or 'full'}")
        for hook, lst in w["multiTaskHooks"].items():
            orders = [x[0] for x in lst]
            if len(set(orders)) > 1:
                p(f"      seri hook {hook}: {lst}")
    p(f"  subflow kenari {len(o['subflowEdges'])} tip={o['subflowTypes']}")
    if o["missingSubflowTargets"]:
        p(f"  !! tanimi olmayan subflow: {o['missingSubflowTargets']}")
    ebl = ", ".join(f"{k}={v}" for k, v in o["errorBoundaryActions"].items())
    p(f"  errorBoundary: {ebl or 'hic tanim yok'}  ({len(o['workflowsWithoutErrorBoundary'])} workflow'da hic yok)")
    for c in o["slotCollisions"]:
        tag = "publish'te reddedilir" if g["ge_0_0_99"] else "calisma aninda cakisma hatasi"
        p(f"  !! ayni order'da ayni slot ({tag}): {c['where']} order={c['order']} slot={c['slot']} {c['tasks']}")
    if o["executionTypeUsed"]:
        p(f"  executionType kullanan workflow: {', '.join(o['executionTypeUsed'])}{gate(g['ge_0_0_99'], '0.0.99')}")
    if o["executionTypeOnAutomatic"]:
        p(f"  !! otomatik transition'da executionType (yok sayilir): {', '.join(o['executionTypeOnAutomatic'])}")
    for grp in o["duplicateWorkflows"]:
        p(f"  !! ayni state kumesine sahip workflow: {', '.join(grp)}")
    for t in o["stateTemplates"]:
        p(f"  tekrarlayan state kalibi x{t['count']}: stateType={t['stateType']} subType={t['subType']} "
          f"trans={t['transitions']} tasks={t['tasks']}")
    p(f"  event transition: {o['eventTransitions']}   $self hedefi: {o['selfTargets']}   loadData:true: {o['loadDataTotal']}")
    h = o["historyNone"]
    if h.get("skipped"):
        p(f"  history none: atlandi ({h['skipped']})")
    else:
        if h["eligible"]:
            names = [k + (f" (+child {','.join(h['withChild'][k])})" if k in h["withChild"] else "") for k in h["eligible"]]
            p(f"  history: none adayi ({len(names)}): {', '.join(names)}{gate(g['ge_0_0_100'], '0.0.100')}")
        if h["alreadyNone"]:
            p(f"  history: none olan: {', '.join(h['alreadyNone'])}{gate(g['ge_0_0_100'], '0.0.100')}")
        for k, why in h["noneButIneligible"].items():
            p(f"  !! history: none ama uygun degil: {k} ({'; '.join(why[:3])})")
    p("")
    p("## extensions")
    for e in o["extensions"]:
        p(f"  {e['key']:38} type={e['type']} scope={e['scope']} task={e['task']} ({e['taskType']})"
          f"{'  NETWORK' if e['network'] else ''}")
    broken = [e["key"] for e in o["extensions"] if e["taskType"] is None]
    if broken:
        p(f"  !! task tanimi bulunamadi: {broken}")
    if o["globalNetworkExtensions"]:
        p(f"  !! global + agli extension (her okumada): {', '.join(o['globalNetworkExtensions'])}")
    for hs in sorted(o["extensionHotStates"], key=lambda x: -x["callsPerRead"]):
        p(f"  !! {hs['workflow']}::{hs['state']} okuma basina {hs['callsPerRead']} agli cagri "
          f"({hs['views']} view): {', '.join(hs['networkExtensions'])}")
    p("")
    p("## functions")
    for fn in o["functions"]:
        p(f"  {fn['key']:44} scope={fn['scope']}({fn['scopeLabel']}) tasks={fn['tasks']} {fn['taskTypes']}"
          f"{' cache' if fn['cache'] else ''}{' executionLog=E' if fn['executionLog'] == 'E' else ''}")
    if o["instanceScopedFunctions"]:
        p(f"  !! instance scope ({len(o['instanceScopedFunctions'])}): {', '.join(o['instanceScopedFunctions'])}")
    if o["workflowFunctionCache"]:
        p(f"  functionCache.ttlSeconds: {o['workflowFunctionCache']}")
    if o["executionLogFunctions"]:
        p(f"  executionLog=E ({len(o['executionLogFunctions'])}; telemetri/depolama hacmi): "
          f"{', '.join(o['executionLogFunctions'])}{gate(g['ge_0_0_99'], '0.0.99')}")
    if o["hierarchyRefs"]:
        tag = "KIRIK (0.0.99'da instance-correlation oldu)" if g["ge_0_0_99"] else "0.0.99'a geciste kirilir"
        p(f"  !! functions/hierarchy referansi ({len(o['hierarchyRefs'])}) — {tag}: {', '.join(o['hierarchyRefs'])}")
    p("")
    p("## olu agirlik")
    for k in ("viewsOrphans", "schemasOrphans", "tasksOrphans"):
        d = o[k]
        p(f"  {k:16} tanimli={d['defined']:3} referanssiz={len(d['unreferenced'])}")
        if d["unreferenced"]:
            p(f"      {', '.join(d['unreferenced'][:20])}{' ...' if len(d['unreferenced']) > 20 else ''}")
    p(f"  schema baglama (transition): bagli={o['schemaBinding']['bound']} null={o['schemaBinding']['null']}")
    p("")
    p("## sorgu / index / gizli bilgi")
    sc = o["scriptCalls"]
    p(f"  GetSecret={sc['GetSecret']} GetConfigValue={sc['GetConfigValue']} context.Related={sc['contextRelated']} "
      f"InstanceQuery(fluent)={sc['InstanceQueryFluent']} JsonSerializer.Serialize={sc['handBuiltFilterJson']} "
      f"(log icinde={sc['serializeInLog']})")
    if o["filterPaths"]:
        p(f"  filtrelenen attributes yolu ({len(o['filterPaths'])}): {', '.join(o['filterPaths'][:12])}"
          f"{' ...' if len(o['filterPaths']) > 12 else ''}")
    p(f"  x-indexed alan: {o['indexedFields']}{gate(g['ge_0_0_94'], '0.0.94')}")
    if o["unindexedQueryFields"]:
        items = [f"{u['schema']}:{u['field']}({'f' if u['filter'] else ''}{'s' if u['sort'] else ''})"
                 for u in o["unindexedQueryFields"]]
        p(f"  !! filtre/siralama var, x-indexed yok ({len(items)}): {', '.join(items[:15])}{' ...' if len(items) > 15 else ''}")
    cf = o["computedFields"]
    if cf["total"]:
        p(f"  x-computed alan (master): {cf['total']} {cf['bySchema']}{gate(g['ge_0_0_100'], '0.0.100')}")
    if cf["evaluatedByServer"]:
        p(f"  !! x-computed evaluatedBy 'server' (0.0.100'de reddedilir): {', '.join(cf['evaluatedByServer'])}")
    p("")
    p("## en agir viewlar")
    for v in o["heaviestViews"]:
        p(f"    {v['bytes']:7} {os.path.relpath(v['file'], o['root'])}")
    p("")
    p("## scriptler")
    s = o["scripts"]
    p(f"  {s['count']} dosya, {s['totalKB']} KB")
    for x in s["largest"][:6]:
        p(f"    {x['bytes']:7} {os.path.relpath(x['file'], o['root'])}")
    e = o["embeddedCode"]
    p(f"  gomulu base64: {e['codeBytes'] // 1024} KB / {e['jsonBytes'] // 1024} KB JSON (%{e['sharePct']}), "
      f"{e['blobs']} blob {e['distinct']} farkli, tekrar {e['duplicateBytes'] // 1024} KB, en cok {e['maxRepeat']}x")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Static scanner for a vNext domain package (domain-check).")
    ap.add_argument("root", nargs="?")
    ap.add_argument("--config")
    ap.add_argument("--schema-dir")
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    root, cfg_path = find_root(args.root, args.config)
    if not root:
        name = args.config or "vnext.config.json"
        print(f"{name} bulunamadi ({os.path.abspath(args.root or os.getcwd())} ve ust klasorleri). "
              "domain-check yalnizca bir vNext domain paketinde calisir.", file=sys.stderr)
        return 2
    res = scan(root, cfg_path, args.schema_dir, args.no_fetch)
    for w in res["workflows"]:
        w["file"] = os.path.relpath(w["file"], root)
    if args.json:
        print(json.dumps(res, indent=2, ensure_ascii=False, default=list))
    else:
        human(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
