#!/usr/bin/env bash
# UserPromptSubmit hook — queries memory-search-daemon over UNIX socket and
# injects top-K semantically relevant memories into the prompt context.
#
# Failsafe: ANY error → echo '{}' and exit 0, never block the user's prompt.

# Re-entrancy guard: if a parent set CLAUDE_HEADLESS (e.g. a capture lobo
# spawning a headless sub-claude), the sub-claude must NOT recursively trigger memory
# search. Exit silently with empty hook output.
[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

trap 'echo "{}"; exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/memory-search.sock"
LOG="$ANTARES_STATE/logs/memory-search.log"

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

# Skip trivial prompts (greetings, acknowledgements).
if (( ${#prompt} < 30 )); then
  echo '{}'
  exit 0
fi

# Daemon down → graceful degradation. This is the normal path before the
# operator runs install.sh — keep silent in logs so it doesn't
# look like an error.
if [[ ! -S "$SOCKET" ]]; then
  printf '%s DAEMON_DOWN prompt=%q\n' "$(date -Iseconds)" "${prompt:0:80}" >>"$LOG" 2>/dev/null || true
  echo '{}'
  exit 0
fi

req=$(jq -nc --arg q "$prompt" --arg cwd "$cwd" \
  '{op:"search",query:$q,cwd:$cwd,scope:"all",top_k:5,threshold:0.35,types:"all"}')

# Query budget. This hook declares `timeout: 5` in settings.json but only ever
# gave the daemon 2 of those 5 seconds — three left unused while queries were
# killed for want of them.
#
# The daemon's own timing log looked reassuring (p99 1569ms, max 1995ms) and was
# censored: anything slower than 2s was killed BEFORE it could report a timing, so
# the slow tail was missing from the very numbers that justified the limit. The
# honest figure is in the TIMEOUT lines — 99 of 4009 attempts on one install,
# 2.5% of prompts answered with zero memories and no way to tell that apart from
# "nothing relevant".
#
# Keep this strictly below the hook's declared timeout: past it the harness kills
# the hook outright and nothing is logged at all.
QUERY_TIMEOUT=${ANTARES_SEARCH_QUERY_TIMEOUT:-4}

q_start=$(date +%s%N)
resp=$(printf '%s\n' "$req" | timeout "$QUERY_TIMEOUT" socat -t "$QUERY_TIMEOUT" - "UNIX-CONNECT:$SOCKET" 2>/dev/null) || {
  # Record how long it actually waited: a timeout with no duration cannot tell a
  # slow daemon from a dead socket, and that is the difference between tuning this
  # number and restarting the service.
  printf '%s TIMEOUT after=%sms budget=%ss prompt=%q\n' \
    "$(date -Iseconds)" "$(( ($(date +%s%N) - q_start) / 1000000 ))" "$QUERY_TIMEOUT" "${prompt:0:80}" >>"$LOG" 2>/dev/null || true
  echo '{}'
  exit 0
}

ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null || echo "false")
if [[ "$ok" != "true" ]]; then
  printf '%s ERROR resp=%q\n' "$(date -Iseconds)" "${resp:0:200}" >>"$LOG" 2>/dev/null || true
  echo '{}'
  exit 0
fi

hits_paths=$(jq -r '.hits[].path' <<<"$resp" 2>/dev/null || true)
if [[ -z "$hits_paths" ]]; then
  printf '%s NOHITS prompt=%q\n' "$(date -Iseconds)" "${prompt:0:80}" >>"$LOG" 2>/dev/null || true
  echo '{}'
  exit 0
fi

# Build the context block, under a byte budget.
#
# This used to `cat` all 5 hits in full, uncapped, on EVERY prompt. Measured over
# 2102 real prompts on one install: median 50 KB injected, p90 117 KB, max 278 KB
# (~71k tokens), with 73.5% of all injected bytes being session journals — the
# cronista's raw substrate rather than curated recall. Nothing surfaced it: the
# log line read "OK hits=5" either way. Not data loss; context and cost burned
# silently on every turn.
#
# A SIZE cap, not a type filter: journals and memories share a ~2 KB median, and
# only the tail hurts. An 8 KB per-file cap touched 6.1% of files there — exactly
# the ones doing the damage — leaving the other 94% injected whole, which is the
# point of curated memories. Result on the same corpus: median 50 KB -> 12 KB,
# max 278 KB -> 28 KB, 79.7% fewer bytes.
#
# Over the cap, the daemon's `snippet` (the chunk that actually matched) goes in
# with the path, so what earned the hit is still present and the rest is one Read
# away. Truncation is LOGGED — a silent cap is just a quieter version of the same
# bug. Both limits are overridable for tuning.
MAX_FILE_BYTES=${ANTARES_INJECT_MAX_FILE:-8192}
MAX_TOTAL_BYTES=${ANTARES_INJECT_MAX_TOTAL:-32768}

ctx=$'<auto-loaded-memory>\nMemories auto-loaded by semantic similarity to your current prompt:\n\n'
n_hits=$(jq -r '.hits | length' <<<"$resp" 2>/dev/null || echo 0)
total=0
trimmed=()
for (( i=0; i<n_hits; i++ )); do
  path=$(jq -r ".hits[$i].path // empty" <<<"$resp" 2>/dev/null)
  [[ -n "$path" && -f "$path" ]] || continue
  size=$(stat -c %s "$path" 2>/dev/null || echo 0)
  name=$(basename "$path")

  if (( size <= MAX_FILE_BYTES && total + size <= MAX_TOTAL_BYTES )); then
    ctx+=$'## '"$name"$'\n\n'"$(cat "$path")"$'\n\n'
    total=$(( total + size ))
  else
    snip=$(jq -r ".hits[$i].snippet // empty" <<<"$resp" 2>/dev/null)
    ctx+=$'## '"$name"$' (excerpt — '"$(( size / 1024 ))"$' KB, Read the file for the rest)\n\n'"$path"$'\n\n'"$snip"$'\n\n'
    total=$(( total + ${#snip} + ${#path} ))
    trimmed+=("$name:$((size/1024))KB")
  fi
done
ctx+=$'</auto-loaded-memory>'

# Log success with hit details.
{
  printf '%s OK timing=%sms hits=%s injected=%sB%s prompt=%q\n' \
    "$(date -Iseconds)" \
    "$(jq -r '.timing_ms' <<<"$resp")" \
    "$n_hits" \
    "$total" \
    "$( (( ${#trimmed[@]} )) && printf ' trimmed=%s' "$(IFS=,; echo "${trimmed[*]}")" )" \
    "${prompt:0:120}"
  jq -r '.hits[] | "  [\(.score)] \(.path)"' <<<"$resp"
} >>"$LOG" 2>/dev/null || true

# Strict JSON output for Claude Code.
jq -nc --arg ctx "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
