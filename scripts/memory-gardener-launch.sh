#!/usr/bin/env bash
# SessionEnd hook — fire-and-forget launcher for the "gardener" lobo.
# The operator delegated hygiene: the gardener ACTS (merges duplicates, removes
# obsolete memories) instead of leaving notes to review. Two-stage safety:
#   (1) the lobo never deletes — it merges survivors (Edit) and WRITES the paths of
#       redundant/obsolete files to a DELETIONS LIST;
#   (2) this launcher takes a FULL backup of the base (tar), then validates and
#       executes each listed deletion (must be a .md inside the memory dir, never
#       MEMORY.md), and reindexes if anything changed.
# Guards: gate ~24h, lock, background+disown. opus/high — it decides destinies now.
#
# Failsafe: ANY error → exit 0. Never block session close.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-gardener.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-gardener.lock"
STAMP="$ANTARES_STATE/gardener-last-run"
PREFS="$ANTARES_STATE/gardener-memory.md"        # persistent memory (operator preferences)
BACKUP_DIR="$ANTARES_STATE/base-backups"
DELLIST="$ANTARES_STATE/gardener-deletions.txt"
# The lobo writes ONE RUN here; the launcher appends it to the permanent changelog.
# Same shape as the cronista's segment-then-append, and for the same reason: the
# lobo has Write and no Bash, and a Write to an existing file REPLACES it. The
# changelog is the only audit trail of the one component in this system that
# deletes an operator's memories, and it holds 40 days of history. Nothing here
# should be one mis-aimed Write away from gone. (Filed as a hypothesis and it did
# NOT reproduce — the run after Bash was removed appended correctly and all 40 days
# survived. This removes the possibility rather than trusting the wording of a
# prompt, because the backups that would have been the fallback rotate away after
# five runs.)
CL_ENTRY="$ANTARES_STATE/gardener-changelog-entry.md"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

now=$(date +%s)

# Gate: at most once per ~24h.
if [[ -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( now - last < 86400 )); then
        log "SKIP gate: last run $(( now - last ))s ago (<24h)"
        exit 0
    fi
fi

# Lock: one gardener at a time. Acquired with flock INSIDE the background subshell
# (see below), never as a lock FILE here: a pid-in-a-file lock is only released by
# a trap, so a lobo killed hard (SIGKILL, OOM, power loss) leaves the file behind
# and every later session SKIPs forever — silently, since a wedged lobo looks
# exactly like a busy one in the log. The kernel releases an flock unconditionally.
# Same pattern as skill-keeper-launch.sh.

home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"
changelog="$home_dir/.gardener-changelog.md"
today=$(date +%Y-%m-%d)

# Full paths as labels — the gardener acts on files (merges, deletion list).
# Body lives in lib/common.sh: one awk pass instead of ~2 processes per memory.
build_digest() {
    antares_build_digest "$1" path
}

digest="$(build_digest "$home_dir")"
if [[ "$current_dir" != "$home_dir" ]]; then
    cur="$(build_digest "$current_dir")"
    [[ -n "$cur" ]] && digest="$digest
$cur"
fi
n_mem=$(printf '%s' "$digest" | grep -c '^- ' || true)
# The lobo's own memory file, CAPPED. It appends to this every run and nothing ever
# shrinks it, so it grows without bound and crowds out the thing the run is actually
# about. Measured on this install: 67,359 B of a 141,843 B prompt — 47% of what the
# gardener reads before it sees a single memory, and most of the tail is a per-run
# log of "no action" entries rather than anything an operator ever expressed.
#
# The head is kept, because that is where this file puts its durable findings, and
# the truncation is declared IN the prompt with the real numbers plus an instruction
# to consolidate. That last part is the only thing that actually reverses the growth:
# $ANTARES_STATE is inside the lobo's write scope, so it can rewrite its own memory,
# and a cap alone would just hide the tail forever.
PREFS_MAX_BYTES=${ANTARES_GARDENER_PREFS_MAX:-8000}
prefs_body=$(cat "$PREFS" 2>/dev/null || echo "(no preferences recorded yet — be extra conservative; record what the operator keeps to your memory file.)")
prefs_bytes=${#prefs_body}
if (( prefs_bytes > PREFS_MAX_BYTES )); then
    prefs_body="${prefs_body:0:$PREFS_MAX_BYTES}

[NOTE: your memory file is ${prefs_bytes} bytes and only the first ${PREFS_MAX_BYTES} are shown.
 CONSOLIDATE IT THIS RUN: rewrite $PREFS keeping the durable findings and the operator's
 stated preferences, and DROP the per-run log entries ('no action', counts, dates) — those
 are already in $changelog. It is inside your write scope.]"
    log "PREFS truncated ${prefs_bytes}B -> ${PREFS_MAX_BYTES}B — asked the lobo to consolidate $PREFS"
fi

task="Today is $today. Keep the base clean by ACTING (merge duplicates, remove obsolete). Do NOT leave notes.

== YOUR MEMORY (operator preferences — read FIRST; update at $PREFS) ==
$prefs_body

== ALL MEMORIES ($n_mem total — full-path: description) ==
$digest

Merge near-duplicates into the best survivor (Edit it). Write the COMPLETE list of redundant/obsolete file paths to $DELLIST (one per line, single Write — the launcher validates + deletes them). Write THIS RUN's changelog entry to $CL_ENTRY (single Write, just this run — the launcher appends it to the permanent changelog; do NOT open $changelog yourself). NEVER touch MEMORY.md. Conservative: when unsure, KEEP. Update your memory at $PREFS if you learned what the operator keeps."

log "LAUNCH gardener (background) cwd=$cwd memories=$n_mem model=${ANTARES_GARDENER_MODEL:-opus}"
(
    flock -n 9 || { log "SKIP lock held"; exit 0; }
    export CLAUDE_HEADLESS=1

    # Deletions list truncated INSIDE the lock, not in the launcher's foreground.
    # The gate is stamped only after a successful run, so a second session closing
    # while a gardener is in flight still passes it. It used to clear this file
    # before reaching the lock — wiping the list the running gardener was still
    # writing into — and then skip on the lock, having already destroyed the other
    # run's work. The surviving list is short, so the launcher under-deletes: safe
    # in direction, silent in effect, and the whole pass is wasted.
    : > "$DELLIST"
    : > "$CL_ENTRY"
    antares_link_sdk "$SCRIPT_DIR/../agents-sdk" || log "SDK not installed — run install.sh (lobo fails rc=1)"

    # FULL backup of the base before the gardener can merge/flag anything.
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    stamp=$(date +%Y%m%d-%H%M%S)
    tar czf "$BACKUP_DIR/base.$stamp.tar.gz" -C "$home_dir" . 2>/dev/null || true
    # The digest above hands the lobo the per-cwd store as well when cwd != $HOME,
    # so it can merge and rewrite memories there — but the backup only ever covered
    # the global store, leaving those edits with no local recovery path. Back up
    # whatever the lobo was actually shown, not just the part we remembered.
    if [[ "$current_dir" != "$home_dir" && -d "$current_dir" ]]; then
        tar czf "$BACKUP_DIR/project-$(basename "$(dirname "$current_dir")").$stamp.tar.gz" \
            -C "$current_dir" . 2>/dev/null || true
    fi
    ls -1t "$BACKUP_DIR"/base.*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f  # keep last 5

    antares_lobo_env "$home_dir${current_dir:+:$current_dir}:$ANTARES_STATE"
    out=$(printf '%s' "$task" | env -i "${ANTARES_LOBO_ENV[@]}" \
        timeout "${ANTARES_GARDENER_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/gardener.mjs" 2>>"$LOG")
    rc=$?
    # Stamp the gate ONLY on success — a failed run (rc!=0) must NOT block the 24h gate,
    # or one failure locks the gardener out for ~24h without ever having run. Retry next close.
    if (( rc == 0 )); then echo "$now" > "$STAMP"; else log "gardener rc=$rc — gate NOT stamped, retries next close"; fi

    # Execute the lobo's deletions list — VALIDATED. This is the only place in the
    # system that deletes an operator's memories, so the check has to hold against
    # a path the lobo got wrong, not just against a path it got right.
    #
    # It is RESOLVED first, because a glob cannot do this job. `case "$p" in
    # "$home_dir"/*.md)` reads like "a .md directly inside the memory dir" and is
    # not: `*` in a case pattern spans '/', so the same pattern also accepts
    #
    #     $home_dir/../../../../../../etc/cron.d/x.md
    #     $home_dir/../../../../home/<user>/.ssh/authorized_keys.md
    #     $home_dir/journal/session-<id>.md
    #
    # — all three verified against the original pattern. The first two are an
    # arbitrary .md delete anywhere the user can write; the third is the cronista's
    # output, which is not this lobo's to remove. The lobo's input derives from
    # memory text and transcripts, so "it would never emit that" is not a control.
    #
    # realpath collapses `..` and follows symlinks, and the survivor must sit
    # EXACTLY in the memory dir — an equality test on the parent, not a prefix
    # match, which also excludes journal/ and any other subdirectory for free.
    #
    # SCOPE = the dirs the lobo was actually SHOWN, which is the global store and,
    # when the session runs outside $HOME, the per-cwd store. It used to be the
    # global store alone, and that made the gardener half-blind in a way that made
    # things worse rather than merely incomplete: the digest hands it project
    # memories, and the write scope exported above lets it Edit them — so it would
    # merge a project duplicate into a survivor and then be refused when it asked
    # for the husk to be removed. Content consolidated, redundant file left behind,
    # and the next run does the same work again. Reproduced against this exact
    # validator: "REFUSE out-of-scope path: .../-home-endymion-<project>/memory/
    # dup-dos.md", deleted=0, file still on disk. The per-cwd store is backed up
    # above alongside the global one, so a deletion here has the same recovery path.
    deleted=0
    home_real=$(realpath -e -- "$home_dir" 2>/dev/null || printf '%s' "$home_dir")
    del_scopes=("$home_real")
    if [[ "$current_dir" != "$home_dir" && -d "$current_dir" ]]; then
        del_scopes+=("$(realpath -e -- "$current_dir" 2>/dev/null || printf '%s' "$current_dir")")
    fi
    if [[ -s "$DELLIST" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            rp=$(realpath -e -- "$p" 2>/dev/null) \
                || { log "REFUSE unresolvable or missing: $p"; continue; }
            # Still an EQUALITY test on the parent, now against each allowed dir —
            # never a prefix match. That is what keeps journal/ (the cronista's
            # output, not this lobo's to remove), any other subdirectory, and any
            # `..` escape out of reach, in both scopes.
            in_scope=0
            for _d in "${del_scopes[@]}"; do
                [[ "$(dirname "$rp")" == "$_d" ]] && { in_scope=1; break; }
            done
            (( in_scope == 1 )) \
                || { log "REFUSE out-of-scope path: $p (resolves to $rp)"; continue; }
            [[ "$rp" == *.md ]]            || { log "REFUSE not a .md: $p"; continue; }
            [[ "$(basename "$rp")" == "MEMORY.md" ]] && { log "REFUSE delete MEMORY.md"; continue; }
            [[ -f "$rp" ]]                 || { log "SKIP not a regular file: $p"; continue; }
            rm -f "$rp" && deleted=$((deleted+1)) && log "DELETED $rp"
        done < "$DELLIST"
    fi

    # Append this run's entry — the permanent changelog is only ever appended to,
    # and only ever by the launcher.
    if [[ -s "$CL_ENTRY" ]]; then
        cl_before=$(stat -c %s "$changelog" 2>/dev/null || echo 0)
        { printf '\n'; cat "$CL_ENTRY"; printf '\n'; } >> "$changelog" 2>>"$LOG"
        cl_after=$(stat -c %s "$changelog" 2>/dev/null || echo 0)
        if (( cl_after > cl_before )); then
            log "CHANGELOG appended $(stat -c %s "$CL_ENTRY")B (${cl_before}B -> ${cl_after}B)"
            rm -f "$CL_ENTRY"
        else
            log "CHANGELOG APPEND FAILED (${cl_before}B unchanged) — entry kept at $CL_ENTRY"
        fi
    fi

    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1000)
    log "DONE rc=$rc deleted=$deleted result=$result"

    # Reindex if the base changed (deleted files must leave the search index).
    if (( deleted > 0 )); then
        # env -u: this subshell exports CLAUDE_HEADLESS=1 and memory-reindex.sh
        # guards on exactly that, so the call returned in ~6 ms having indexed
        # nothing — meaning every file the gardener deleted stayed in the search
        # index, and searches kept returning hits for memories that no longer
        # exist. Same dead-call shape as the one in the chronicle launcher.
        env -u CLAUDE_HEADLESS bash "$SCRIPT_DIR/memory-reindex.sh" >/dev/null 2>&1 || true
    fi
) 9>>"$LOCK" >/dev/null 2>&1 &
disown

exit 0
