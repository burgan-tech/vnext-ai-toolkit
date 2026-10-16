#!/bin/sh
# e2e-preflight.sh — environment check before /vnext-ai-toolkit:e2e runs the integration tests.
# Read-only: never starts containers, never writes files, never edits the workspace.
#
# Usage: e2e-preflight.sh [--root DIR] [--mode container|local] [--port 4201] [--host localhost]
#   container (default)  Testcontainers: the SDK starts PostgreSQL/Redis/Vault/Dapr/runtime images
#   local                an already running runtime (vnext-runtime released images or vNext Forge)
#
# Output: one line per check — OK / INFO / WARN / STOP. STOP means the chosen mode cannot run
# (the e2e skill then asks the user or switches mode). Exit 0 = runnable, 3 = at least one STOP.
set -u

root="."; mode="container"; port="4201"; host="localhost"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$mode" in container|local) ;; *) echo "--mode must be container or local" >&2; exit 2 ;; esac

stops=0
ok()   { printf 'OK   %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
stop() { printf 'STOP %s\n' "$*"; stops=$((stops + 1)); }

cd "$root" 2>/dev/null || { echo "STOP cannot enter $root"; exit 3; }
echo "== e2e preflight ($mode mode) in $(pwd)"

# ---- workspace ---------------------------------------------------------------
if [ ! -f vnext.config.json ]; then stop "no vnext.config.json — run /vnext-ai-toolkit:vnext-init first"; exit 3; fi
if ! command -v node >/dev/null 2>&1; then stop "node not found (needed for npm run validate and this check)"; exit 3; fi
cfg() { node -e 'const c=require(process.argv[1]);const v=process.argv[2].split(".").reduce((o,k)=>o&&o[k],c);process.stdout.write(v==null?"":String(v))' "$(pwd)/vnext.config.json" "$1"; }
domain=$(cfg domain); runtime=$(cfg runtimeVersion); croot=$(cfg paths.componentsRoot); [ -n "$croot" ] || croot="$domain"
ok "domain '$domain', runtimeVersion $runtime, components under $croot/"

# ---- tools -------------------------------------------------------------------
if command -v dotnet >/dev/null 2>&1; then
  sdk_major=$(dotnet --list-sdks 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p' | sort -n | tail -1)
  if [ -n "$sdk_major" ] && [ "$sdk_major" -ge 10 ]; then ok ".NET SDK $sdk_major.x"; else stop ".NET 10 SDK required for the test project (found: ${sdk_major:-none})"; fi
else stop "dotnet not found — install the .NET 10 SDK"; fi

docker_up=0
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then docker_up=1; ok "Docker daemon running"; else
    if [ "$mode" = container ]; then stop "Docker daemon not running (Testcontainers needs it)"; else warn "Docker daemon not running — MockLab/runtime container checks skipped"; fi
  fi
else
  if [ "$mode" = container ]; then stop "docker not found (Testcontainers needs Docker)"; else warn "docker not found — container checks skipped"; fi
fi

# ---- test project ------------------------------------------------------------
proj=$(find . -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -not -path '*/node_modules/*' 2>/dev/null \
       | while IFS= read -r p; do grep -q 'VNext.Testing.Sdk' "$p" && echo "$p"; done | head -1)
if [ -z "$proj" ]; then
  stop "no test project (no *.csproj references VNext.Testing.Sdk) — integration-test skill or /vnext-ai-toolkit:vnext-init Step 7"
  pdir=""
else
  pdir=$(dirname "$proj"); ok "test project $proj"
  sdkv=$(sed -n 's/.*Include="VNext.Testing.Sdk"[^>]*Version="\([^"]*\)".*/\1/p' "$proj" | head -1)
  case "$sdkv" in
    1.0.0) warn "VNext.Testing.Sdk $sdkv is not on nuget.org (latest published: 0.0.6) — set Version=\"0.0.6\"" ;;
    "") info "VNext.Testing.Sdk version not found in $proj" ;;
    *) ok "VNext.Testing.Sdk $sdkv" ;;
  esac
  grep -q 'Xunit.SkippableFact' "$proj" || info "Xunit.SkippableFact not referenced — needed for Skip.If(...) on optional dependencies"
  grep -q 'test.runsettings.local' "$proj" || warn "csproj has no RunSettingsFilePath fallback to test.runsettings.local (IDE runs ignore the local file)"
  [ -f "$pdir/Infrastructure/WorkflowTestBase.cs" ] || info "no Infrastructure/WorkflowTestBase.cs (async transition / wait-for-state / lock-retry helpers) — template: templates/tests/WorkflowTestBase.cs.tmpl"
fi

# active (uncommented) VNEXT_BASE_URL in a runsettings file
active_url() { [ -f "$1" ] && sed 's/<!--.*-->//g' "$1" | awk '/<!--/{c=1} !c{print} /-->/{c=0}' | sed -n 's/.*<VNEXT_BASE_URL>\(.*\)<\/VNEXT_BASE_URL>.*/\1/p' | head -1; }
if [ -n "$pdir" ]; then
  committed=$(active_url "$pdir/test.runsettings"); local_url=$(active_url "$pdir/test.runsettings.local")
  if [ -f "$pdir/test.runsettings.local" ]; then
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git check-ignore -q "$pdir/test.runsettings.local" && ok "test.runsettings.local is git-ignored" || warn "test.runsettings.local is NOT git-ignored — add '*.runsettings.local' to .gitignore"
    fi
  fi
  effective="${VNEXT_BASE_URL:-${local_url:-$committed}}"
  if [ "$mode" = container ] && [ -n "$effective" ]; then
    stop "VNEXT_BASE_URL resolves to $effective (env > test.runsettings.local > test.runsettings) — the SDK will use that runtime, not Testcontainers. Unset it for container mode."
  fi
  if [ "$mode" = local ] && [ -n "$effective" ] && [ "$effective" != "http://$host:$port" ]; then
    warn "VNEXT_BASE_URL resolves to $effective but local mode targets http://$host:$port — write test.runsettings.local (with approval)"
  fi
  [ -n "$committed" ] && info "committed test.runsettings sets VNEXT_BASE_URL=$committed (toolkit default keeps it commented: container mode)"
fi

# ---- container mode: what the SDK would start -----------------------------------
envf="$pdir/Infrastructure/VNextTestEnvironment.cs"
if [ "$mode" = container ] && [ -n "$pdir" ]; then
  if [ -f "$envf" ]; then
    code=$(sed 's#//.*##' "$envf")
    if printf '%s' "$code" | grep -q 'VNextImageVersion'; then ok "VNextImageVersion overridden (verify it equals runtimeVersion $runtime)"
    else warn "VNextImageVersion not overridden — SDK default is 'latest', not runtime $runtime. Template: templates/tests/VNextTestEnvironment.cs.tmpl"; fi
    printf '%s' "$code" | grep -q 'DaprSidecarImage' || warn "DaprSidecarImage not pinned — SDK default daprio/daprd:latest (toolkit pins 1.18.0)"
    printf '%s' "$code" | grep -q 'MocklabImage' || info "MocklabImage not pinned — SDK default ghcr.io/burgan-tech/mocklab:latest (toolkit pins 0.0.10)"
    if printf '%s' "$code" | grep -q 'runtime/publish'; then ok "system package (@burgan-tech/vnext-core-runtime) is loaded in OnAfterEnvironmentReadyAsync"
    else warn "system package not loaded: SDK 0.0.6 starts no init container and never publishes @burgan-tech/vnext-core-runtime. Flows that reference sys-* components fail. Use the template's LoadSystemPackageAsync or run in local mode"; fi
  else warn "no $envf — the SDK runs with image tag 'latest'"; fi
  if [ "$docker_up" -eq 1 ]; then
    for img in orchestrator execution inbox outbox db-migrator; do
      docker image inspect "ghcr.io/burgan-tech/vnext/$img:$runtime" >/dev/null 2>&1 || { info "image ghcr.io/burgan-tech/vnext/$img:$runtime not pulled yet (first run pulls ~GBs)"; break; }
    done
  fi
fi

# ---- local mode: a running runtime ---------------------------------------------
if [ "$mode" = local ]; then
  if ! command -v curl >/dev/null 2>&1; then stop "curl not found"; else
    body=$(curl -s -m 3 "http://$host:$port/health" 2>/dev/null)
    if [ -z "$body" ]; then stop "no runtime answers http://$host:$port/health — start vnext-runtime (make up-vnext DOMAIN=$domain) or Forge, or use container mode"
    else
      rdomain=$(printf '%s' "$body" | sed -n 's/.*"domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      rver=$(printf '%s' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      rstat=$(printf '%s' "$body" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      [ "$rstat" = "Healthy" ] && ok "runtime on :$port is Healthy" || warn "runtime on :$port reports status '${rstat:-?}'"
      if [ -n "$rdomain" ] && [ "$rdomain" != "$domain" ]; then stop "runtime on :$port serves domain '$rdomain', workspace domain is '$domain' — wrong port?"
      else ok "runtime domain '${rdomain:-?}'"; fi
      case "$rver" in "$runtime"*) ok "runtime version $rver" ;; "") info "runtime did not report a version" ;;
        *) warn "runtime version $rver ≠ vnext.config.json runtimeVersion $runtime — results describe $rver" ;; esac
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$host:$port/api/v1/$domain/workflows/sys-flows/instances?pageSize=1" 2>/dev/null)
      [ "$code" = 200 ] && ok "system flows answer (sys-flows instances list 200)" \
        || warn "could not confirm the system package (sys-flows list answered ${code:-nothing}) — on a fresh DB load @burgan-tech/vnext-core-runtime once through the domain's init container (vnext-runtime does this in vnext-component-publisher)"
    fi
  fi
fi

# ---- MockLab ---------------------------------------------------------------------
uses_http=0
if grep -rlqE '"type"[[:space:]]*:[[:space:]]*"6"' "$croot" 2>/dev/null; then uses_http=1; fi
hard=$(grep -rlE '"url"[[:space:]]*:[[:space:]]*"https?://(localhost|127\.0\.0\.1)' "$croot" 2>/dev/null | head -5)
if [ -n "$hard" ]; then
  warn "task URL(s) hard-code localhost — breaks whenever the runtime runs in a container (Testcontainers or vnext-runtime). Use the API_BASEURL placeholder + GetConfigValue: $(printf '%s ' $hard)"
fi
if [ "$mode" = local ] && [ "$uses_http" -eq 1 ]; then
  if curl -s -o /dev/null -m 3 "http://$host:3001/" 2>/dev/null; then ok "MockLab answers on :3001"; else warn "MockLab not reachable on :3001 — docker compose up -d (after the runtime infra)"; fi
  if [ "$docker_up" -eq 1 ] && docker inspect mocklab >/dev/null 2>&1; then
    nets=$(docker inspect mocklab --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
    case " $nets " in *" ${VNEXT_NETWORK:-vnext-development} "*) ok "mocklab is on network ${VNEXT_NETWORK:-vnext-development}" ;;
      *) warn "mocklab is on [$nets], not ${VNEXT_NETWORK:-vnext-development} — runtime containers cannot reach http://mocklab:5000" ;; esac
  fi
fi

# ---- x-storage (blob binding) ------------------------------------------------------
bindings=$(node -e '
const fs=require("fs"),path=require("path"),out=new Set();
const walk=d=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);
  if(e.isDirectory()){if(!["node_modules",".meta"].includes(e.name))walk(p);}
  else if(p.endsWith(".json")){let j;try{j=JSON.parse(fs.readFileSync(p,"utf8"));}catch{continue;}
    const visit=o=>{if(o&&typeof o==="object"){const s=o["x-storage"];if(s&&typeof s.binding==="string")out.add(s.binding);Object.values(o).forEach(visit);}};visit(j);}}};
try{walk(process.argv[1]);}catch{} process.stdout.write([...out].sort().join(" "));' "$croot")
for b in $bindings; do
  if [ "$mode" = container ]; then
    if [ -n "$pdir" ] && grep -rlq "name:[[:space:]]*$b" "$pdir/Infrastructure/DaprComponents/orchestration" 2>/dev/null; then
      ok "x-storage binding '$b' present in Infrastructure/DaprComponents/orchestration"
      info "container mode: SDK daprd runs without --max-body-size (default 4Mi) — keep test files small"
    else warn "x-storage binding '$b' missing for the SDK orchestration sidecar → start/transition answer 503 Instance:100047. Template: templates/tests/DaprComponents/orchestration/vnext-blob-local.yaml.tmpl"; fi
  elif [ "$docker_up" -eq 1 ]; then
    sc="vnext-orchestration-dapr-$domain"
    if docker inspect "$sc" >/dev/null 2>&1; then
      args=$(docker inspect "$sc" --format '{{json .Args}} {{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null)
      case "$args" in *max-body-size*) ;; *) warn "sidecar $sc runs without --max-body-size (uploads > 4Mi fail)";; esac
      case "$args" in *domain-components*|*"/blobs"*) ok "sidecar $sc has the blob overlay mounted" ;;
        *) warn "x-storage binding '$b' not mounted on $sc — apply etc/runtime/docker-compose.blob.override.yml (see etc/runtime/README.md)" ;; esac
    else info "x-storage binding '$b': cannot inspect sidecar $sc (Forge or another layout) — make sure the binding exists or starts answer 503 Instance:100047"; fi
  fi
done

# ---- script plugins ------------------------------------------------------------
if grep -rlq '"allowedAssemblies"' "$croot" 2>/dev/null; then
  if [ "$mode" = container ]; then
    warn "allowedAssemblies used: SDK 0.0.6 cannot bind-mount a plugin directory into the orchestrator — run those suites in local mode (Scripting__Sandbox__PluginDirectory)"
  elif [ "$docker_up" -eq 1 ] && docker inspect "vnext-app-$domain" >/dev/null 2>&1; then
    docker inspect "vnext-app-$domain" --format '{{json .Config.Env}}' 2>/dev/null | grep -q 'Scripting__Sandbox__PluginDirectory' \
      && ok "plugin directory configured on vnext-app-$domain" || warn "allowedAssemblies used but vnext-app-$domain has no Scripting__Sandbox__PluginDirectory — those functions are rejected at publish"
  else info "allowedAssemblies used — the runtime needs Scripting__Sandbox__PluginDirectory"; fi
fi

# ---- caller-role provider ------------------------------------------------------------
if [ -n "$pdir" ] && grep -rlq 'VNEXT_CALLER_ROLE_PROVIDER' "$pdir" 2>/dev/null; then
  if [ "${VNEXT_CALLER_ROLE_PROVIDER:-}" = "morph-idm" ]; then info "morph-idm provider tests enabled (runtime must run with CallerRoleProvider__Provider=morph-idm)"
  else info "morph-idm provider tests will skip (VNEXT_CALLER_ROLE_PROVIDER unset)"; fi
fi

# ---- ports (local mode) ------------------------------------------------------------
if [ "$mode" = local ] && command -v lsof >/dev/null 2>&1; then
  for p in "$port" 3001 3005; do
    who=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$who" ] && info "port $p is served by '$who'"
  done
fi

if [ "$stops" -gt 0 ]; then echo "== $stops blocking item(s) for $mode mode"; exit 3; fi
echo "== preflight passed for $mode mode (warnings do not block)"
exit 0
