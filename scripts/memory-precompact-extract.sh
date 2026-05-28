#!/usr/bin/env bash
# PreCompact hook — spawn headless `claude -p` to extract durable memories
# from the transcript before context compression discards conversation history.
#
# Failsafe: ANY error → exit 0 with log. Never block compaction.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-precompact.log"
PROMPT_FILE="$SCRIPT_DIR/memory-precompact-prompt.txt"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-precompact.lock"

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
trigger=$(printf '%s' "$input" | jq -r '.trigger // "unknown"' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

log "INVOKED session=$session_id trigger=$trigger cwd=$cwd transcript=$transcript_path"

# Need venv (sub-claude doesn't use it, but project_root detection does run
# either way — bail if install hasn't happened so we don't pretend to extract).
if ! antares_venv_ready; then
    log "SKIP venv not ready ($ANTARES_VENV_PY)"
    exit 0
fi

# Detect project root via the same walk-up the indexer uses, so we can tell
# the sub-claude where (if anywhere) the project memory lives. Empty string
# means "no project context" → only global memory is available.
project_root=""
if [[ -n "$cwd" && "$cwd" != "$HOME"/.claude && "$cwd" != "$HOME"/.claude/* ]]; then
    probe="$cwd"
    while [[ -n "$probe" && "$probe" != "/" && "$probe" != "$HOME" ]]; do
        if [[ -d "$probe/.claude/memory" ]]; then
            project_root="$probe"
            break
        fi
        probe="$(dirname "$probe")"
    done
fi
log "PROJECT_ROOT=${project_root:-<none>}"

if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    log "SKIP no transcript_path or file missing"
    exit 0
fi

# Single-flight lock — prevent concurrent extractors (rare manual+auto race).
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP another extractor running (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi
trap 'rm -f "$LOCK"' EXIT

# Pre-process: extract user/assistant text from the JSONL transcript so the
# sub-claude doesn't burn turns iterating through 2-5MB of raw tool calls and
# tool results. Cap at last 100KB (~25K tokens) to keep extraction tractable.
PREPARED="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-precompact-prepared.md"
{
    echo "# Conversation transcript (text content only, last ~100KB)"
    echo ""
    jq -r '
      select(.type == "user" or .type == "assistant") |
      .message.content[]? |
      select(.type == "text") |
      "## [" + (.type // "unknown") + "]\n\n" + .text + "\n"
    ' "$transcript_path" 2>>"$LOG" | tail -c 100000
} > "$PREPARED"
prepared_size=$(stat -c %s "$PREPARED" 2>/dev/null || echo 0)
log "PREPARED size=${prepared_size}B path=$PREPARED"

if [[ -n "$project_root" ]]; then
    project_block="The parent session's CWD is:
  $cwd

It is inside the project rooted at:
  $project_root

This project has its own memory store at:
  $project_root/.claude/memory/

Decide per memory: write to GLOBAL ($CLAUDE_MEMORY_HOME/) for cross-cutting lessons (tool quirks, OS gotchas, behavioral feedback applicable to any project, deep app knowledge as tool_*). Write to PROJECT ($project_root/.claude/memory/) for context that only matters inside this codebase (architecture decisions, ongoing TODOs, project-specific gotchas, client info)."
else
    project_block="The parent session's CWD is:
  $cwd

It is NOT inside any project (no <ancestor>/.claude/memory/ found). Write all extracted memories to GLOBAL ($CLAUDE_MEMORY_HOME/)."
fi

sub_prompt="Compaction is about to happen for session $session_id (trigger=$trigger).

Read the pre-extracted text-only transcript at:
  $PREPARED

It contains the user and assistant messages from the recent session (capped at last ~100KB), with tool calls and tool results stripped. Extract durable memories worth saving.

$project_block

Follow the policy in your appended system prompt strictly. Dedup before writing (grep + ls in BOTH global and project memory dirs if applicable). When done, print the EXTRACTION SUMMARY block and exit. Do not wait for input."

start=$(date +%s)
export CLAUDE_HEADLESS=1

log "BEFORE_CLAUDE"
# Disable ERR trap during the claude call — inherited in $() subshells is what
# was aborting the whole script on the first sub-claude failure.
# Text output (no --json-schema) is cheaper: half the turns, half the cost.
# Output is for logging only — the real artifacts are the memory .md files
# that the sub-claude writes via Write/Edit tools.
trap - ERR
set +e
output=$(timeout --kill-after=5 "$ANTARES_PRECOMPACT_TIMEOUT" claude -p "$sub_prompt" \
    --model "$ANTARES_PRECOMPACT_MODEL" \
    --output-format json \
    --max-budget-usd "$ANTARES_PRECOMPACT_BUDGET" \
    --no-session-persistence \
    --permission-mode bypassPermissions \
    --append-system-prompt-file "$PROMPT_FILE" \
    </dev/null 2>>"$LOG")
rc=$?
log "AFTER_CLAUDE rc=$rc output_len=${#output}"
trap 'exit 0' ERR
set -e
elapsed=$(( $(date +%s) - start ))

if (( rc == 124 || rc == 137 )); then
    log "TIMEOUT after ${elapsed}s rc=$rc"
elif (( rc != 0 )); then
    # Detect budget-exceeded — common case, logged distinctly so it's obvious.
    subtype=$(printf '%s' "$output" | jq -r '.subtype // empty' 2>/dev/null || true)
    cost=$(printf '%s' "$output" | jq -r '.total_cost_usd // "?"' 2>/dev/null || echo "?")
    if [[ "$subtype" == "error_max_budget_usd" ]]; then
        log "BUDGET_EXCEEDED rc=$rc elapsed=${elapsed}s spent=\$$cost — files written before cap may be present"
    else
        log "ERROR rc=$rc elapsed=${elapsed}s subtype=$subtype cost=\$$cost"
        printf '%s' "$output" | head -c 800 >>"$LOG"
        printf '\n' >>"$LOG"
    fi
else
    cost=$(printf '%s' "$output" | jq -r '.total_cost_usd // .usage.cost_usd // "?"' 2>/dev/null || echo "?")
    turns=$(printf '%s' "$output" | jq -r '.num_turns // "?"' 2>/dev/null || echo "?")
    log "OK elapsed=${elapsed}s cost=$cost turns=$turns"
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null | head -c 2000)
    [[ -n "$result" ]] && log "RESULT: $result"
fi

# Reindex global + project (if any) so the next UserPromptSubmit sees the
# newly-written memories immediately. Run synchronously.
log "REINDEX global start"
if timeout 60 "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope global >>"$LOG" 2>&1; then
    log "REINDEX global done"
else
    log "REINDEX global failed rc=$?"
fi

if [[ -n "$project_root" ]]; then
    log "REINDEX project start (root=$project_root)"
    if timeout 60 "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope project --cwd "$project_root" >>"$LOG" 2>&1; then
        log "REINDEX project done"
    else
        log "REINDEX project failed rc=$?"
    fi
fi

exit 0
