#!/usr/bin/env bash
# check-prerequisites.sh — invoked by /vnext-init to verify the workspace has the tooling we'll need.
# Prints a summary; exits 0 if all required tools are present, exits 1 if any required tool is missing.

set -u

# Tools we check. Required = the workspace cannot proceed without it. Optional = warn only.
REQUIRED=("node" "npm" "git")
OPTIONAL=("docker" "docker compose" "dotnet")

missing_required=0
missing_optional=0

check_one() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1 || ($cmd --version >/dev/null 2>&1); then
    local ver
    ver=$($cmd --version 2>/dev/null | head -1)
    printf "  ✓ %-20s %s\n" "$cmd" "$ver"
    return 0
  else
    return 1
  fi
}

echo "vnext-init prerequisite check"
echo "------------------------------"

echo "Required:"
for cmd in "${REQUIRED[@]}"; do
  if ! check_one "$cmd"; then
    printf "  ✗ %-20s MISSING\n" "$cmd"
    missing_required=$((missing_required + 1))
  fi
done

echo
echo "Optional:"
for cmd in "${OPTIONAL[@]}"; do
  if ! check_one "$cmd"; then
    printf "  - %-20s not found (some steps will be skipped)\n" "$cmd"
    missing_optional=$((missing_optional + 1))
  fi
done

echo
if [[ $missing_required -gt 0 ]]; then
  echo "✗ $missing_required required tool(s) missing — install them before running /vnext-init."
  exit 1
fi

if [[ $missing_optional -gt 0 ]]; then
  echo "⚠ $missing_optional optional tool(s) missing — vnext-init will skip the corresponding steps."
fi

echo "✓ Prerequisites OK."
exit 0
