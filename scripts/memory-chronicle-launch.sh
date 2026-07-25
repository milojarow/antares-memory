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

# Advance the watermark and PROVE it landed. `echo > file` is not guaranteed: a
# full state filesystem, a read-only mount, a watermark file left owned by root by
# a run under sudo — any of them fail here, and the launcher used to log
# "watermark advanced -> N" on the strength of having tried.
#
# Measured: with the file chmod 444 and 16 lines of new transcript, the log said
# `watermark advanced -> 16` while the file still held 8. Every later run then
# re-extracted the same delta and appended the same chronicle to the journal
# again — duplication, permanent, reported as success. The journal append twenty
# lines below already verifies itself by comparing sizes; this did not.
advance_watermark() {
    local want=$1 got
    if echo "$want" > "$WM_FILE" 2>>"$LOG"; then
        got=$(cat "$WM_FILE" 2>/dev/null || true)
        if [[ "$got" == "$want" ]]; then
            log "watermark advanced -> $want"
            return 0
        fi
    fi
    log "WATERMARK WRITE FAILED (file still '$(cat "$WM_FILE" 2>/dev/null || true)', wanted $want) — the next run re-chronicles this same delta and the journal will duplicate it. Check permissions and free space on $WM_FILE."
    return 1
}

antares_trim_logs

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
# Cheap pre-filter only — the authoritative read happens under the lock below.
# Safe as an optimisation because a watermark only ever grows: a stale value here
# can only be too LOW, which sends us on to the real check, never too high.
wm=$(cat "$WM_FILE" 2>/dev/null || echo 0)
total=$(wc -l < "$transcript_path" 2>/dev/null || echo 0)
(( total <= wm )) && { log "SKIP nothing new (total=$total <= wm=$wm)"; exit 0; }

# Lock per session (covers a PreCompact + SessionEnd near-collision).
#
# flock on an inherited FD, NOT a pid-in-a-file: the pid file is only removed by a
# trap, so a pipeline killed hard (SIGKILL, OOM, power loss) leaves it behind and
# every later close of THAT session skips forever — silently, because a wedged
# lobo and a busy one log the same line. Observed in production: one long-running
# session logged 8 consecutive `SKIP lock held` over 6 days, all naming the same
# already-dead pid, losing every journal entry in that window, while other
# sessions were unaffected (this lock is per session_id). It only cleared because
# the runtime dir is a tmpfs and the machine happened to reboot — luck, not
# design. The kernel releases an flock unconditionally, however the holder dies.
#
# FD 9 is opened here and INHERITED by the background pipeline below, so the lock
# spans the foreground prep and the lobos, and is released when they finish.
# Never `rm` the lock file while holding it: a second process would create a new
# inode and lock that one instead, and both would think they were alone.
# EVERYTHING from here runs DETACHED, and the lock is taken inside it.
#
# It used to be acquired in the hook's foreground, ~170 lines before the dispatch,
# with `flock -w 600` for SessionEnd — inside a hook that declares `timeout: 30`.
# Reproduced: with the lock held by a PreCompact pipeline (139s-5min in
# production), the hook ran 32004 ms and was killed rc=124. It never reached the
# delta, never dispatched, never advanced the watermark, and never wrote the SKIP
# line either — that line is unreachable, because 600s of waiting cannot fit in a
# 30s budget. The log simply stopped, indistinguishable from a run that never
# happened, and SessionEnd is the LAST trigger a closed session ever fires, so
# nothing retried it.
#
# Detached, the wait costs nobody anything: the hook returns immediately and the
# pipeline waits its turn on its own time.
log "LAUNCH chronicle pipeline (background) event=$event session=$session_id"
(
exec 9>>"$LOCK"
# PreCompact can skip — the session is still open and SessionEnd will come. But
# SessionEnd is the LAST trigger this session will ever fire: if it skips because
# a PreCompact pipeline still holds the lock (those runs take minutes), the final
# segment of the transcript is never chronicled and never retried, because nothing
# else will ever fire for a closed session. So it waits instead. This launcher is
# already fire-and-forget in the background, so waiting costs nobody anything.
if [[ "$event" == "SessionEnd" ]]; then
    lock_wait=${ANTARES_CHRONICLE_LOCK_WAIT:-600}
    if ! flock -w "$lock_wait" 9; then
        log "SKIP lock still held after ${lock_wait}s (SessionEnd) — final delta lost"
        exit 0
    fi
elif ! flock -n 9; then
    log "SKIP lock held (a chronicle for this session is already running)"
    exit 0
fi

# Re-read UNDER the lock. The values read in the foreground are from before the
# wait, and whoever held the lock was very likely a pipeline for this same session
# that advanced the watermark while we waited. Cutting the delta with the stale
# number hands the cronista turns it has already chronicled — the exact duplication
# this file's header promises cannot happen.
wm=$(cat "$WM_FILE" 2>/dev/null || echo 0)
total=$(wc -l < "$transcript_path" 2>/dev/null || echo 0)
log "watermark=$wm total_lines=$total (under lock)"
(( total <= wm )) && { log "SKIP nothing new under lock (total=$total <= wm=$wm)"; exit 0; }

# Extract the DELTA: new .jsonl lines [wm+1 .. total], preprocessed to user/assistant
# text (same jq shape the old extractor used — strips tool calls/results).
# Cap at last ~300KB: bounds the delta so the lobo never chokes on a multi-MB
# backlog (a session reanimated with no watermark, defaults to 0). 300KB ≈ 75K
# tokens — well under sonnet's ~200K ceiling — and covers a full long session up
# to a compact (measured: a long real session ran ~190KB of user/assistant text).
# 100KB was too tight: it dropped ~half of such a session. From the next trigger
# on it's truly incremental (only the new tramo). Already-CLOSED historical
# sessions never fire a hook, so they're never processed at all.
#
# `tail` keeps the MOST RECENT text and drops the oldest — deliberate, but it is a
# real loss and it used to be invisible. The log printed `delta size=300032B`,
# which is the cap and not a warning, so a chronicle written from a beheaded
# segment looked exactly like one written from the whole thing. Measured here: the
# cap has already fired once in production, on a single long session — repeated
# cronista failures are NOT required to reach it (deltas: median 17 KB, p90 99 KB,
# max 300032 B against the 300000 B cap).
DELTA_MAX_BYTES=${ANTARES_DELTA_MAX_BYTES:-300000}
delta="$DELTA_DIR/$session_id.md"
delta_raw="$DELTA_DIR/.$session_id.raw"
{
    # Two defects lived in this filter, both silent, both measured on real data.
    #
    # 1. `.message.content[]?` DROPPED EVERY TURN THE OPERATOR TYPED. A typed prompt
    #    stores `.message.content` as a plain STRING, not an array; `[]` on a string
    #    is an error and the `?` swallowed it. 575 messages of that shape in one
    #    project's transcripts alone. The human's own words — the instructions, the
    #    corrections, the "no, do it this way" — never reached the cronista or the
    #    destilador. Only the assistant's restatement of them did.
    #
    # 2. `(.type // "unknown")` was evaluated AFTER descending into the content
    #    block, so it read the BLOCK's type ("text"), never the message's. Every
    #    entry came out labelled `## [text]` and the lobos could not tell who said
    #    what — in a chronicle, that is most of the meaning.
    #
    # The message is captured in `$msg` before descending, a string body is wrapped
    # into the same shape as an array body, and the label is the message's role.
    # tool_result and thinking blocks stay excluded by the `select` below, which is
    # what keeps the delta to actual conversation (7812 tool_result blocks here).
    #
    # Measured across 73 real transcripts: 3,342,521 -> 3,725,672 bytes of extracted
    # text. 383 KB, 11.5%, that the capture pipeline had never seen.
    # 3. A SINGLE malformed line used to discard everything after it. jq parses a
    #    stream and ABORTS on the first bad record, so one truncated line — which
    #    is not exotic, the hook reads the transcript while Claude Code is still
    #    appending to it — took the rest of the session with it. Measured on a
    #    transcript of 5 good records, 1 broken, 5 good: 5 emitted, 5 dropped. With
    #    the break on line 1: 0 of 5 emitted. And the watermark advances to the full
    #    line count either way, so the dropped material is marked captured forever.
    #
    #    `-R` + `fromjson?` parses line by line and SKIPS what won't parse instead of
    #    giving up on the file. Each skip goes to the log, because a filter that
    #    quietly eats records is the same failure wearing a better disguise.
    awk -v s=$((wm + 1)) 'NR>=s' "$transcript_path" | jq -Rr '
        select(length > 0) |
        (fromjson? // ("[skip] unparseable transcript line dropped: " + .[0:70] + "\n" | stderr | empty)) |
        select(.type == "user" or .type == "assistant") |
        . as $msg |
        (if (.message.content | type) == "string"
           then [{type: "text", text: .message.content}]
           else (.message.content // []) end) |
        .[] |
        select(.type == "text") |
        "## [" + ($msg.type // "unknown") + "]\n\n" + .text + "\n"
    ' 2>>"$LOG"
} > "$delta_raw" 2>>"$LOG"
raw_size=$(stat -c %s "$delta_raw" 2>/dev/null || echo 0)
{
    echo "# Session delta (new since line $wm) — $(date '+%Y-%m-%d %H:%M')"
    echo ""
    if (( raw_size > DELTA_MAX_BYTES )); then
        # Tell the lobo too, not just the log: a chronicle that opens mid-thought
        # should say so rather than read as if that were the start of the session.
        echo "[NOTE: this segment was truncated to its last ${DELTA_MAX_BYTES} bytes;"
        echo " $(( raw_size - DELTA_MAX_BYTES )) bytes of EARLIER material are missing from the front.]"
        echo ""
    fi
    tail -c "$DELTA_MAX_BYTES" "$delta_raw"
} > "$delta" 2>>"$LOG"
rm -f "$delta_raw"
delta_size=$(stat -c %s "$delta" 2>/dev/null || echo 0)
if (( raw_size > DELTA_MAX_BYTES )); then
    log "delta size=${delta_size}B TRUNCATED from ${raw_size}B — $(( raw_size - DELTA_MAX_BYTES ))B of the oldest material dropped"
else
    log "delta size=${delta_size}B"
fi

# Gate por sustancia: a near-empty delta (open/close, greeting) isn't worth a lobo.
# Advance the watermark anyway so it doesn't re-trigger on the same trivial tail.
if (( delta_size < 400 )); then
    log "SKIP delta trivial (${delta_size}B) — advancing watermark, no lobos"
    advance_watermark "$total"
    # Only the delta, and only if it is still there: a previously failed run moved
    # it to .retry, which the sweep owns. Never the lock FILE — see the flock note
    # above; exiting closes FD 9 and that is what releases it.
    [[ -f "$delta" ]] && rm -f "$delta"
    exit 0
fi

# Project scope for the destilador: the cwd's slug dir (the same convention the
# indexer, the search and the gardener resolve — anything else would write
# memories nothing ever indexes or recalls).
project_dir=""
if [[ -n "$cwd" && "$cwd" != "$HOME" && "$cwd" != "$HOME"/.claude && "$cwd" != "$HOME"/.claude/* ]]; then
    project_dir="$(antares_memory_dir_for "$cwd")"
fi

home_dir="$(antares_home_memory_dir)"
journal_dir="$home_dir/journal"
mkdir -p "$journal_dir" 2>/dev/null || true
journal="$journal_dir/session-$session_id.md"
today=$(date +%Y-%m-%d)

# The cronista writes a SEGMENT; this launcher appends it. Same split as the
# gardener's deletions: the lobo produces a proposal in a file of its own and the
# launcher performs the irreversible part. It is what let the cronista give up
# Bash — appending to a growing journal was the only thing it needed a shell for,
# and Read-then-Write-the-whole-file risks losing prior chronicles, which its own
# policy forbids. Nothing is appended unless the lobo exits 0 AND left content.
segment="$DELTA_DIR/$session_id.segment.md"
rm -f "$segment"

cronista_task="Today is $today. Chronicle the NEW session activity.

DELTA (new transcript segment, text only): $delta
SEGMENT (write your chronicle HERE, single Write; the launcher appends it): $segment
JOURNAL (context only — read if useful, never write to it): $journal

Write a dated chronicle of the delta per your policy. If the delta has no real work, write nothing."

# Digest of existing memories (filename: description) for FAST dedup — same trick the
# curator/gardener use, so the destilador checks candidates against an inline list
# instead of Grep+Read over 150 files (that timed it out at 300s).
# Filenames as labels — the destilador dedups by memory name, it doesn't open files.
# Body lives in lib/common.sh: one awk pass instead of ~2 processes per memory. This
# runs in the FOREGROUND of the hook (before the background dispatch below), and this
# launcher fires on EVERY close with no cadence gate, so its cost is paid every time:
# the per-file shape it replaces measured seconds at a few hundred memories and grew
# with the store.
build_mem_digest() {
    antares_build_digest "$1" name
}
mem_digest="$(build_mem_digest "$home_dir")"
if [[ -n "$project_dir" && -d "$project_dir" ]]; then
    mem_digest="$mem_digest
$(build_mem_digest "$project_dir")"
fi

if [[ -n "$project_dir" ]]; then
    mem_block="MEMORY DIRS:
  HOME (cross-cutting): $home_dir
  PROJECT (cwd-specific slug for $cwd): $project_dir"
else
    mem_block="MEMORY DIR (all to HOME — cwd is \$HOME): $home_dir"
fi
destilador_task="Distill durable memories from the NEW session activity.

REAL SESSION ID (use verbatim for each memory's metadata.originSessionId): $session_id
DELTA (new transcript segment, text only): $delta
$mem_block

EXISTING MEMORIES (filename: description — dedup against THIS inline list, do NOT Grep all files):
$mem_digest

Per your policy: durable lessons/facts only, conservative, never the journal nor MEMORY.md. Dedup each candidate against the digest above; only Read a specific file if you must confirm before enriching."

    # No lock cleanup needed: the kernel drops the flock when this subshell exits,
    # including when it is killed.
    export CLAUDE_HEADLESS=1
    # Self-heal the SDK symlink in the deploy dir (symlink → stable install, survives updates).
    antares_link_sdk "$SCRIPT_DIR/../agents-sdk" || log "SDK not installed — run install.sh (lobos fail rc=1)"

    # 1. cronista → journal
    # Write scope, per lobo. The cronista only ever writes its own SEGMENT file —
    # the launcher does the journal append — so that is the entire scope it needs.
    antares_lobo_env "$DELTA_DIR"
    c_out=$(printf '%s' "$cronista_task" | env -i "${ANTARES_LOBO_ENV[@]}" \
        timeout "${ANTARES_CRONISTA_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/cronista.mjs" 2>>"$LOG")
    c_rc=$?
    c_res=$(printf '%s' "$c_out" | jq -r '.result // empty' 2>/dev/null | head -c 300)
    log "CRONISTA rc=$c_rc result=$c_res"

    # Advance the watermark after the cronista (the journal is the primary capture).
    # If the cronista failed, leave it so the same delta is retried next run.
    # Append the lobo's segment to the journal — the launcher's job, not the lobo's.
    # Only on success and only with content: a failed run must not leave a partial
    # chronicle behind, and "nothing durable happened" is a legitimate outcome that
    # writes no segment at all.
    # `captured` gates BOTH the cleanup and the watermark below. The cronista
    # exiting 0 is not the same thing as the chronicle being safe: it says the lobo
    # wrote its segment, not that the segment reached the journal. Keying cleanup on
    # rc alone meant that when the append failed the launcher logged
    # "segment kept at <path>", deleted that exact file, and advanced the watermark
    # anyway — the chronicle destroyed, the material it came from skipped forever,
    # and the only log line pointing at a file removed milliseconds earlier.
    # Reproduced with a read-only journal.
    captured=0
    if (( c_rc == 0 )) && [[ -s "$segment" ]]; then
        seg_bytes=$(stat -c %s "$segment" 2>/dev/null || echo 0)
        before=$(stat -c %s "$journal" 2>/dev/null || echo 0)
        { printf '\n'; cat "$segment"; printf '\n'; } >> "$journal" 2>>"$LOG"
        after=$(stat -c %s "$journal" 2>/dev/null || echo 0)
        if (( after > before )); then
            log "JOURNAL appended ${seg_bytes}B (journal ${before}B -> ${after}B)"
            captured=1
        else
            # The recovery path is the HELD-BACK WATERMARK, not this file: the next
            # run re-extracts the same delta and chronicles it again. The segment is
            # left on disk for inspection only.
            log "JOURNAL APPEND FAILED (journal ${before}B unchanged) — watermark held back, whole delta retried next run; segment left at $segment"
        fi
    elif (( c_rc == 0 )); then
        # Nothing to chronicle is a legitimate, complete outcome: there is no
        # content at risk, so the watermark must advance or this trivial delta is
        # re-processed on every close forever.
        log "no segment written (delta had nothing to chronicle)"
        captured=1
    fi

    # Remove the segment only once its content is safely in the journal.
    (( captured == 1 )) && [[ -f "$segment" ]] && rm -f "$segment"

    if (( c_rc == 0 && captured == 1 )); then
        advance_watermark "$total"
    elif (( c_rc != 0 )); then
        log "watermark NOT advanced (cronista rc=$c_rc) — delta retried next run"
    else
        log "watermark NOT advanced (chronicle never reached the journal) — delta retried next run"
    fi

    # 0. Sweep: one delta left behind by a previously failed distillation gets a
    # second attempt before new work. Oldest first, ONE per run — a persistent
    # failure must not become a backlog crowding out the live session, and the
    # attempt is consumed either way (evidence in the log, not a growing queue).
    #
    # The session id comes from the FILENAME, not this run's $session_id: the
    # pending delta belongs to whichever session failed, and stamping its memories
    # with the current id would quietly corrupt originSessionId — a wrong answer is
    # worse than a missing one.
    # Runs ONLY when this run's own cronista succeeded. A run whose cronista just
    # failed is a run with something wrong — SDK, auth, timeout — and spending
    # another session's one retry attempt inside it burned the attempt on
    # conditions that had nothing to do with that delta. The sweep used to sit
    # ABOVE the `c_rc != 0` gate that skips distillation for exactly that reason.
    pending=""
    if (( c_rc == 0 )); then
        candidate=$(ls -1tr "$DELTA_DIR"/*.md.retry 2>/dev/null | head -1)
        # CLAIM IT ATOMICALLY. The retry queue is global state, but the lock around
        # this block is per SESSION, so two sessions closing at once both list the
        # same file and both distil it — duplicate memories from one delta, in
        # parallel. `mv` is the arbiter: whoever moves it first wins, and the loser's
        # mv fails because the source no longer exists.
        if [[ -n "$candidate" ]]; then
            claimed="$candidate.claimed.$$"
            if mv "$candidate" "$claimed" 2>/dev/null; then
                pending="$claimed"
            else
                log "RETRY skipped: another run claimed $(basename "$candidate") first"
            fi
        fi
    fi
    if [[ -n "$pending" && -f "$pending" ]]; then
        r_sid=$(basename "$pending"); r_sid="${r_sid%.md.retry.claimed.$$}"
        # Rebuild the scope from the cwd of the session that PRODUCED this delta,
        # not from ours. Falls back to the global store when the sidecar is absent
        # (a delta stranded by an older version), which is the safe direction: a
        # memory in the global store is findable, one in the wrong project slug is
        # not.
        r_cwd=$(cat "$pending.cwd" 2>/dev/null || cat "${pending%.claimed.$$}.cwd" 2>/dev/null || true)
        r_home="$home_dir"
        r_project=""
        if [[ -n "$r_cwd" && "$r_cwd" != "$HOME" && "$r_cwd" != "$HOME"/.claude && "$r_cwd" != "$HOME"/.claude/* ]]; then
            r_project="$(antares_memory_dir_for "$r_cwd")"
        fi
        if [[ -n "$r_project" ]]; then
            r_mem_block="MEMORY DIRS:
  HOME (cross-cutting): $r_home
  PROJECT (cwd-specific slug for $r_cwd): $r_project"
            r_digest="$(antares_build_digest "$r_home" name)
$(antares_build_digest "$r_project" name)"
        else
            r_mem_block="MEMORY DIR (all to HOME): $r_home"
            r_digest="$(antares_build_digest "$r_home" name)"
        fi
        log "RETRY distilling session=$r_sid delta=$pending scope=${r_project:-home}"
        r_task="Distill durable memories from the NEW session activity.

REAL SESSION ID (use verbatim for each memory's metadata.originSessionId): $r_sid
DELTA (new transcript segment, text only): $pending
$r_mem_block

EXISTING MEMORIES (filename: description — dedup against THIS inline list, do NOT Grep all files):
$r_digest
"
        antares_lobo_env "$home_dir${project_dir:+:$project_dir}"
        r_out=$(printf '%s' "$r_task" | env -i "${ANTARES_LOBO_ENV[@]}" \
            timeout "${ANTARES_DISTILLER_TIMEOUT:-480}" \
            node "$SCRIPT_DIR/../agents-sdk/destiller.mjs" 2>>"$LOG")
        r_rc=$?
        log "RETRY rc=$r_rc result=$(printf '%s' "$r_out" | jq -r '.result // empty' 2>/dev/null | head -c 200)"
        # Deleted only when the attempt actually succeeded. On failure it is kept
        # as .spent — out of the sweep's reach so it can never become a permanent
        # queue, but still on disk instead of destroyed, because a delta whose
        # distillation failed twice is exactly the one worth looking at.
        if (( r_rc == 0 )); then
            rm -f "$pending" "$pending.cwd" "${pending%.claimed.$$}.cwd" 2>/dev/null
        else
            mv -f "$pending" "${pending%.claimed.$$}.spent" 2>/dev/null \
                && log "RETRY failed rc=$r_rc — kept as $(basename "${pending%.claimed.$$}").spent"
            rm -f "$pending.cwd" "${pending%.claimed.$$}.cwd" 2>/dev/null
        fi
    fi

    # 2. destilador → memories (chained, same delta the cronista just chronicled).
    #
    # Only if the cronista actually succeeded. When it failed the watermark was
    # deliberately held back so the delta is retried next run — but the destilador
    # ran anyway on that same delta, so the retry distils it a SECOND time, from a
    # lobo that dedups against a digest of names and cannot see it already wrote
    # these memories once. Skipping here costs nothing: the whole delta is retried
    # intact, chronicle and distillation together.
    if (( c_rc != 0 )); then
        log "SKIP destilador (cronista rc=$c_rc) — whole delta retried next run"
    else
    antares_lobo_env "$home_dir${project_dir:+:$project_dir}"
    d_out=$(printf '%s' "$destilador_task" | env -i "${ANTARES_LOBO_ENV[@]}" \
        timeout "${ANTARES_DISTILLER_TIMEOUT:-480}" \
        node "$SCRIPT_DIR/../agents-sdk/destiller.mjs" 2>>"$LOG")
    d_rc=$?
    d_res=$(printf '%s' "$d_out" | jq -r '.result // empty' 2>/dev/null | head -c 300)
    log "DESTILADOR rc=$d_rc result=$d_res"

    # The watermark advanced on the cronista's success above — the journal is the
    # primary capture and re-chronicling would duplicate entries. That meant a
    # destilador failure discarded the delta permanently: chronicled, never
    # distilled, never retried. Measured on one install: 5 of 327 runs (3 timeouts,
    # 2 errors), each a session's memories silently never written. Kept for exactly
    # one more attempt by the sweep at the top of the next run.
    if (( d_rc != 0 )); then
        if mv -f "$delta" "$delta.retry" 2>/dev/null; then
            # Persist the cwd alongside it. The sweep that picks this up runs in a
            # DIFFERENT session, and without this it rebuilt the memory scope from
            # ITS OWN cwd — writing this session's memories into another project's
            # slug and deduping them against the wrong set. The original commit
            # was careful to carry originSessionId across and forgot the
            # destination, which is the half that decides where the file lands.
            printf '%s\n' "$cwd" > "$delta.retry.cwd" 2>/dev/null || true
            log "RETRY-PENDING delta kept for one more attempt: $delta.retry"
        fi
    fi
    fi

    # Reindex so the new journal + memories are searchable next session.
    # This call was dead: the subshell exports CLAUDE_HEADLESS=1 (correctly — it
    # stops the lobos re-triggering hooks) and memory-reindex.sh's first line is a
    # guard on that variable, so it returned in ~6 ms having indexed nothing, on
    # every run. The guard is right; the call has to opt out of it for this child.
    [[ -f "$SCRIPT_DIR/memory-reindex.sh" ]] && \
        env -u CLAUDE_HEADLESS bash "$SCRIPT_DIR/memory-reindex.sh" >/dev/null 2>&1 || true

    rm -f "$delta"
) >/dev/null 2>&1 &
disown

exit 0
