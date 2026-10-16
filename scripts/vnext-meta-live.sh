#!/bin/sh
# Prints one vnext-meta JSON file, read live from burgan-tech/vnext master (the source of truth).
# Falls back to the toolkit's offline snapshot (references/runtime-feature-matrix.md) when offline.
#
# Usage:
#   scripts/vnext-meta-live.sh <file> [--ref <git ref>] [--max-age <seconds>]
#     <file>: features | known-issues | deprecations | migrations | version-manifest |
#             security-policy | performance-profiles | component-registry | package  (".json" optional)
#
# Examples:
#   scripts/vnext-meta-live.sh known-issues | node -e 'JSON.parse(require("fs").readFileSync(0)).items.forEach(i=>console.log(i.id, i.fixedIn||"open", i.title))'
#   scripts/vnext-meta-live.sh features --ref v0.0.100
#
# Cache: ${XDG_CACHE_HOME:-$HOME/.cache}/vnext-ai-toolkit/vnext-meta/<ref>/<file>.json, 1 hour by default.
# Exit codes: 0 = printed live or cached JSON; 3 = offline and no cache (snapshot path printed to stderr); 2 = bad usage.
set -eu

[ $# -ge 1 ] || { sed -n '2,16p' "$0" >&2; exit 2; }
name=${1%.json}; shift
ref=master
max_age=3600
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --max-age) max_age="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$name" in
  features|known-issues|deprecations|migrations|version-manifest|security-policy|performance-profiles|component-registry|package) ;;
  *) echo "unknown vnext-meta file: $name" >&2; exit 2 ;;
esac

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vnext-ai-toolkit/vnext-meta/$ref"
cache="$cache_dir/$name.json"
url="https://raw.githubusercontent.com/burgan-tech/vnext/$ref/vnext-meta/$name.json"

fresh() {
  [ -s "$cache" ] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
  [ $((now - mtime)) -lt "$max_age" ]
}

if ! fresh; then
  mkdir -p "$cache_dir"
  tmp="$cache.tmp.$$"
  if curl -fsSL --max-time 15 "$url" -o "$tmp" 2>/dev/null; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp"
    if [ -s "$cache" ]; then
      echo "vnext-meta-live: offline, using cached $name.json from $(date -r "$cache" 2>/dev/null || echo 'an earlier run')" >&2
    else
      echo "vnext-meta-live: could not reach $url and no cache; use the offline snapshot $here/references/runtime-feature-matrix.md" >&2
      exit 3
    fi
  fi
fi
cat "$cache"
