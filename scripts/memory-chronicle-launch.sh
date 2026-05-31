#!/usr/bin/env bash
# SessionEnd + PreCompact hook — fire-and-forget launcher for the chronicle pipeline.
#
#   transcript ──[cronista]──▶ journal ──[destilador]──▶ memories
#
# A per-session WATERMARK (lines of the .jsonl already processed) gives the cronista
# only the NEW segment (delta). The cronista appends that delta's chronicle to the
# session journal; the destilador then distills durable memories from the SAME delta.
# One watermark → the destilador can't re-process old material, so journal and
# memories never duplicate (that was the operator's core concern).
#
# Runs on BOTH PreCompact (compaction = partial close) and SessionEnd (real close),
# always fire-and-forget so it never blocks compaction or session close.
# Failsafe: ANY error → exit 0.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-chronicle.log"
WM_DIR="$ANTARES_STATE/cronista-watermarks"
DELTA_DIR="$ANTARES_STATE/cronista-deltas"
mkdir -p "$WM_DIR" "$DELTA_DIR" 2>/dev/null || true

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
reason=$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

log "INVOKED event=$event reason=$reason session=$session_id transcript=$transcript_path"

[[ -z "$transcript_path" || ! -f "$transcript_path" ]] && { log "SKIP no transcript"; exit 0; }
[[ -z "$session_id" ]] && { log "SKIP no session_id"; exit 0; }
# resume is not an ending — the cronista runs at real closes / compactions.
[[ "$reason" == "resume" ]] && { log "SKIP reason=resume"; exit 0; }

WM_FILE="$WM_DIR/$session_id"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-chronicle-$session_id.lock"
wm=$(cat "$WM_FILE" 2>/dev/null || echo 0)
total=$(wc -l < "$transcript_path" 2>/dev/null || echo 0)
log "watermark=$wm total_lines=$total"
(( total <= wm )) && { log "SKIP nothing new (total=$total <= wm=$wm)"; exit 0; }

# Lock per session (covers a PreCompact + SessionEnd near-collision).
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP lock held (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi

# Extract the DELTA: new .jsonl lines [wm+1 .. total], preprocessed to user/assistant
# text (same jq shape the old extractor used — strips tool calls/results).
# Cap at last ~300KB: bounds the delta so the lobo never chokes on a multi-MB
# backlog (a session reanimated with no watermark, defaults to 0). 300KB ≈ 75K
# tokens — well under sonnet's ~200K ceiling — and covers a full long session up
# to a compact (measured: a long real session ran ~190KB of user/assistant text).
# 100KB was too tight: it dropped ~half of such a session. From the next trigger
# on it's truly incremental (only the new tramo). Already-CLOSED historical
# sessions never fire a hook, so they're never processed at all.
delta="$DELTA_DIR/$session_id.md"
{
    echo "# Session delta (new since line $wm) — $(date '+%Y-%m-%d %H:%M')"
    echo ""
    awk -v s=$((wm + 1)) 'NR>=s' "$transcript_path" | jq -r '
        select(.type == "user" or .type == "assistant") |
        .message.content[]? |
        select(.type == "text") |
        "## [" + (.type // "unknown") + "]\n\n" + .text + "\n"
    ' 2>>"$LOG" | tail -c 300000
} > "$delta" 2>>"$LOG"
delta_size=$(stat -c %s "$delta" 2>/dev/null || echo 0)
log "delta size=${delta_size}B"

# Gate por sustancia: a near-empty delta (open/close, greeting) isn't worth a lobo.
# Advance the watermark anyway so it doesn't re-trigger on the same trivial tail.
if (( delta_size < 400 )); then
    log "SKIP delta trivial (${delta_size}B) — advancing watermark, no lobos"
    echo "$total" > "$WM_FILE"
    rm -f "$LOCK" "$delta"
    exit 0
fi

# Project detection (same walk-up the extractor used) for the destilador's scope.
project_root=""
if [[ -n "$cwd" && "$cwd" != "$HOME"/.claude && "$cwd" != "$HOME"/.claude/* ]]; then
    probe="$cwd"
    while [[ -n "$probe" && "$probe" != "/" && "$probe" != "$HOME" ]]; do
        [[ -d "$probe/.claude/memory" ]] && { project_root="$probe"; break; }
        probe="$(dirname "$probe")"
    done
fi

home_dir="$(antares_home_memory_dir)"
journal_dir="$home_dir/journal"
mkdir -p "$journal_dir" 2>/dev/null || true
journal="$journal_dir/session-$session_id.md"
today=$(date +%Y-%m-%d)

cronista_task="Today is $today. Chronicle the NEW session activity to the journal.

DELTA (new transcript segment, text only): $delta
JOURNAL (append your chronicle here; create if absent): $journal

Append a dated chronicle of the delta per your policy. If the delta has no real work, write nothing."

# Digest of existing memories (filename: description) for FAST dedup — same trick the
# curator/gardener use, so the destilador checks candidates against an inline list
# instead of Grep+Read over 150 files (that timed it out at 300s).
build_mem_digest() {
    local dir="$1" f b d
    shopt -s nullglob
    for f in "$dir"/*.md; do
        b=$(basename "$f"); [[ "$b" == "MEMORY.md" ]] && continue
        d=$(grep -m1 '^description:' "$f" 2>/dev/null | sed -E 's/^description:[[:space:]]*//; s/^"//; s/"$//')
        [[ -z "$d" ]] && d="(no description)"
        printf -- '- %s: %s\n' "$b" "$d"
    done
    shopt -u nullglob
}
mem_digest="$(build_mem_digest "$home_dir")"
if [[ -n "$project_root" && -d "$project_root/.claude/memory" ]]; then
    mem_digest="$mem_digest
$(build_mem_digest "$project_root/.claude/memory")"
fi

if [[ -n "$project_root" ]]; then
    mem_block="MEMORY DIRS:
  HOME (cross-cutting): $home_dir
  PROJECT (cwd-specific, rooted at $project_root): $project_root/.claude/memory"
else
    mem_block="MEMORY DIR (all to HOME — no project under cwd): $home_dir"
fi
destilador_task="Distill durable memories from the NEW session activity.

REAL SESSION ID (use verbatim for each memory's metadata.originSessionId): $session_id
DELTA (new transcript segment, text only): $delta
$mem_block

EXISTING MEMORIES (filename: description — dedup against THIS inline list, do NOT Grep all files):
$mem_digest

Per your policy: durable lessons/facts only, conservative, never the journal nor MEMORY.md. Dedup each candidate against the digest above; only Read a specific file if you must confirm before enriching."

log "LAUNCH chronicle pipeline (background) event=$event session=$session_id"
(
    trap 'rm -f "$LOCK"' EXIT
    export CLAUDE_HEADLESS=1
    # Resolve the SDK from the per-version cache (symlink → stable install, survives updates).
    antares_link_sdk "$SCRIPT_DIR/../agents-sdk" || log "SDK not installed — run /antares-memory:install (lobos fail rc=1)"

    # 1. cronista → journal
    c_out=$(printf '%s' "$cronista_task" | timeout "${ANTARES_CRONISTA_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/cronista.mjs" 2>>"$LOG")
    c_rc=$?
    c_res=$(printf '%s' "$c_out" | jq -r '.result // empty' 2>/dev/null | head -c 300)
    log "CRONISTA rc=$c_rc result=$c_res"

    # Advance the watermark after the cronista (the journal is the primary capture).
    # If the cronista failed, leave it so the same delta is retried next run.
    if (( c_rc == 0 )); then
        echo "$total" > "$WM_FILE"
        log "watermark advanced -> $total"
    else
        log "watermark NOT advanced (cronista rc=$c_rc) — delta retried next run"
    fi

    # 2. destilador → memories (chained, same delta the cronista just chronicled).
    d_out=$(printf '%s' "$destilador_task" | timeout "${ANTARES_DISTILLER_TIMEOUT:-480}" \
        node "$SCRIPT_DIR/../agents-sdk/destiller.mjs" 2>>"$LOG")
    d_rc=$?
    d_res=$(printf '%s' "$d_out" | jq -r '.result // empty' 2>/dev/null | head -c 300)
    log "DESTILADOR rc=$d_rc result=$d_res"

    # Reindex so the new journal + memories are searchable next session.
    [[ -f "$SCRIPT_DIR/memory-reindex.sh" ]] && bash "$SCRIPT_DIR/memory-reindex.sh" >/dev/null 2>&1 || true

    rm -f "$delta"
) >/dev/null 2>&1 &
disown

exit 0
