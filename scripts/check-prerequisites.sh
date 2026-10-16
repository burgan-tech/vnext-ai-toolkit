#!/bin/sh
# check-prerequisites.sh — invoked by /vnext-init to verify the workspace tooling.
# Authoring needs node, npm and git (missing → exit 1). Local end-to-end tests additionally need
# Docker (daemon running), docker compose and the .NET 10 SDK; those are reported as WARN for e2e and
# never fail the check — authoring works without them.
set -u

missing_required=0
e2e_warn=0

ver() { "$@" 2>/dev/null | head -1; }

echo "vnext-init prerequisite check"
echo "------------------------------"
echo "Required (authoring):"
for cmd in node npm git; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  ok   %-16s %s\n' "$cmd" "$(ver "$cmd" --version)"
  else
    printf '  MISS %-16s required\n' "$cmd"
    missing_required=$((missing_required + 1))
  fi
done

echo
echo "Local e2e / integration tests (warn only):"
if command -v docker >/dev/null 2>&1; then
  printf '  ok   %-16s %s\n' docker "$(ver docker --version)"
  if docker info >/dev/null 2>&1; then
    printf '  ok   %-16s %s\n' "docker daemon" "running"
  else
    printf '  WARN %-16s %s\n' "docker daemon" "not running — start Docker Desktop before /vnext-ai-toolkit:e2e"
    e2e_warn=$((e2e_warn + 1))
  fi
  if docker compose version >/dev/null 2>&1; then
    printf '  ok   %-16s %s\n' "docker compose" "$(ver docker compose version)"
  else
    printf '  WARN %-16s %s\n' "docker compose" "missing — MockLab compose cannot start"
    e2e_warn=$((e2e_warn + 1))
  fi
else
  printf '  WARN %-16s %s\n' docker "missing — Testcontainers and MockLab need Docker"
  e2e_warn=$((e2e_warn + 1))
fi

if command -v dotnet >/dev/null 2>&1; then
  major=$(dotnet --list-sdks 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p' | sort -n | tail -1)
  if [ -n "$major" ] && [ "$major" -ge 10 ]; then
    printf '  ok   %-16s %s\n' dotnet "SDK $major.x"
  else
    printf '  WARN %-16s %s\n' dotnet "SDK ${major:-none} found — the integration test project targets net10.0 (install the .NET 10 SDK)"
    e2e_warn=$((e2e_warn + 1))
  fi
else
  printf '  WARN %-16s %s\n' dotnet "missing — install the .NET 10 SDK to build and run the integration tests"
  e2e_warn=$((e2e_warn + 1))
fi

echo
if [ "$missing_required" -gt 0 ]; then
  echo "FAIL $missing_required required tool(s) missing — install them before running /vnext-init."
  exit 1
fi
if [ "$e2e_warn" -gt 0 ]; then
  echo "WARN $e2e_warn e2e prerequisite(s) missing — authoring works; the test project can still be scaffolded, but /vnext-ai-toolkit:e2e cannot run yet."
fi
echo "Prerequisites OK for authoring."
exit 0
