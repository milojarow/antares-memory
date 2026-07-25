#!/usr/bin/env bash
# memory-journal-init.sh — SessionStart hook: create today's journal file
# (in the HOME slug's memory dir, by convention) and inject today's +
# yesterday's journal content as additionalContext.

[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Journal lives in the HOME slug's memory dir — one journal regardless of cwd.
JOURNAL_DIR="$(antares_home_memory_dir)/journal"
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d 'yesterday' +%Y-%m-%d)
TODAY_FILE="$JOURNAL_DIR/$TODAY.md"
YESTERDAY_FILE="$JOURNAL_DIR/$YESTERDAY.md"
MAX_TODAY=15000
MAX_YESTERDAY=8000

mkdir -p "$JOURNAL_DIR" 2>/dev/null || { echo '{}'; exit 0; }

if [[ ! -f "$TODAY_FILE" ]]; then
    cat > "$TODAY_FILE" <<EOF
# Journal: $TODAY

## Sessions

EOF
fi

context=""

# The cronista's ACTUAL output: journal/session-<id>.md, one per session.
#
# This hook only looked at the daily YYYY-MM-DD.md files, and the cronista stopped
# writing those in favour of per-session journals. Since then it creates the daily
# file as a ~36-byte stub, the >50-byte content gate rejects it, and the hook
# returns '{}' on EVERY session start — indistinguishable from "no journal yet",
# which is why it went unnoticed for two months on one install while 173 session
# journals piled up beside it, never once injected.
#
# The daily file is still honoured below: it remains the documented place to write
# notes by hand before a compaction. It just is not what the cronista writes.
#
# Capped, because injected context is not free.
MAX_SESSIONS=${ANTARES_JOURNAL_MAX_SESSIONS:-3}
MAX_SESSION_BYTES=${ANTARES_JOURNAL_MAX_SESSION_BYTES:-12000}
session_ctx=""
session_total=0
if [[ -d "$JOURNAL_DIR" ]]; then
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        (( sz > 50 )) || continue
        remaining=$(( MAX_SESSION_BYTES - session_total ))
        (( remaining > 500 )) || break
        body=$(head -c "$remaining" "$f")
        (( sz > remaining )) && body+=$'\n[... truncated for context efficiency ...]'
        session_ctx+="### $(basename "$f")"$'\n'"$body"$'\n\n'
        session_total=$(( session_total + ${#body} ))
    done < <(ls -1t "$JOURNAL_DIR"/session-*.md 2>/dev/null | head -n "$MAX_SESSIONS")
fi
[[ -n "$session_ctx" ]] && context+="<journal-recent-sessions>"$'\n'"$session_ctx""</journal-recent-sessions>"$'\n'


# Yesterday's journal (if it exists and has meaningful content).
if [[ -f "$YESTERDAY_FILE" ]] && [[ -s "$YESTERDAY_FILE" ]] && (( $(wc -c < "$YESTERDAY_FILE") > 50 )); then
    yesterday_content=$(head -c "$MAX_YESTERDAY" "$YESTERDAY_FILE")
    (( $(wc -c < "$YESTERDAY_FILE") > MAX_YESTERDAY )) && yesterday_content+=$'\n[... truncated for context efficiency ...]'
    # `+=`, not `=`. This single character discarded the recent-sessions block
    # assembled above whenever yesterday's journal had content — and the block it
    # threw away is the larger one, up to MAX_SESSION_BYTES across the last few
    # sessions. Reproduced: with no yesterday file the hook injects
    # <journal-recent-sessions>; drop a yesterday file in and it injects
    # <journal-yesterday> alone, the other block simply gone. It stayed hidden here
    # because the day files are created as an empty 36-byte template and only pass
    # the 50-byte gate on days that actually got written up.
    context+="<journal-yesterday>"$'\n'"$yesterday_content"$'\n'"</journal-yesterday>"$'\n'
fi

# Today's journal.
if [[ -s "$TODAY_FILE" ]] && (( $(wc -c < "$TODAY_FILE") > 50 )); then
    today_content=$(head -c "$MAX_TODAY" "$TODAY_FILE")
    (( $(wc -c < "$TODAY_FILE") > MAX_TODAY )) && today_content+=$'\n[... truncated for context efficiency ...]'
    context+="<journal-today>"$'\n'"$today_content"$'\n'"</journal-today>"
fi

if [[ -z "$context" ]]; then
    echo '{}'
    exit 0
fi

# Emit via jq, not a hand-rolled escaper.
#
# The previous version escaped only \\ " \\n \\r \\t. Every other C0 control character
# went through raw and produced JSON the harness cannot parse. That stayed invisible
# while this hook carried only hand-written notes; it broke the moment it started
# carrying session journals, whose text comes from transcripts and does contain
# control bytes. jq escapes the whole class, and every other hook here uses it.
jq -nc --arg ctx "$context" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
