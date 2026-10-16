#!/bin/sh
# vnext-ai-toolkit PostToolUse hook (Write|Edit|MultiEdit).
# When a workflow definition under */Workflows/*.json was written, check whether any integration test
# references that workflow (scripts/check-test-coverage.sh, gate G2) and, if none does, add a short
# reminder to Claude's context. Warn-only: never blocks, always exits 0, prints nothing otherwise.

input=$(cat 2>/dev/null)
# "file_path":"..." from tool_input (no jq dependency)
file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
case "$file" in
  */Workflows/*.json) ;;
  *) exit 0 ;;
esac
case "$file" in *.diagram.json|*/.meta/*) exit 0 ;; esac

dir="${CLAUDE_PROJECT_DIR:-.}"
[ -f "$dir/vnext.config.json" ] || exit 0
script="${CLAUDE_PLUGIN_ROOT:-}/scripts/check-test-coverage.sh"
[ -f "$script" ] || exit 0

warn=$(sh "$script" --root "$dir" --workflow "$file" --quiet 2>/dev/null | grep 'G2' | head -1)
[ -n "$warn" ] || exit 0

# keep the message JSON-safe: drop quotes/backslashes, single line
warn=$(printf '%s' "$warn" | tr -d '"\\' | tr '\n' ' ')
msg="[vnext-ai-toolkit] ${warn#WARN }. Integration tests are expected for every workflow (warn-only): offer the integration-test skill now, or record that the user skipped it."
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
exit 0
