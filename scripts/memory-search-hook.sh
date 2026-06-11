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

resp=$(printf '%s\n' "$req" | timeout 2 socat -t 2 - "UNIX-CONNECT:$SOCKET" 2>/dev/null) || {
  printf '%s TIMEOUT prompt=%q\n' "$(date -Iseconds)" "${prompt:0:80}" >>"$LOG" 2>/dev/null || true
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

# Build context block: full content of each hit file.
ctx=$'<auto-loaded-memory>\nMemories auto-loaded by semantic similarity to your current prompt:\n\n'
while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  ctx+=$'## '"$(basename "$path")"$'\n\n'"$(cat "$path")"$'\n\n'
done <<<"$hits_paths"
ctx+=$'</auto-loaded-memory>'

# Log success with hit details.
{
  printf '%s OK timing=%sms hits=%s prompt=%q\n' \
    "$(date -Iseconds)" \
    "$(jq -r '.timing_ms' <<<"$resp")" \
    "$(jq -r '.hits | length' <<<"$resp")" \
    "${prompt:0:120}"
  jq -r '.hits[] | "  [\(.score)] \(.path)"' <<<"$resp"
} >>"$LOG" 2>/dev/null || true

# Strict JSON output for Claude Code.
jq -nc --arg ctx "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
