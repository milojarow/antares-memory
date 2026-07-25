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
prefs_body=$(cat "$PREFS" 2>/dev/null || echo "(no preferences recorded yet — be extra conservative; record what the operator keeps to your memory file.)")

task="Today is $today. Keep the base clean by ACTING (merge duplicates, remove obsolete). Do NOT leave notes.

== YOUR MEMORY (operator preferences — read FIRST; update at $PREFS) ==
$prefs_body

== ALL MEMORIES ($n_mem total — full-path: description) ==
$digest

Merge near-duplicates into the best survivor (Edit it). Write the COMPLETE list of redundant/obsolete file paths to $DELLIST (one per line, single Write — the launcher validates + deletes them). Log every action to $changelog. NEVER touch MEMORY.md. Conservative: when unsure, KEEP. Update your memory at $PREFS if you learned what the operator keeps."

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

    out=$(printf '%s' "$task" | ANTARES_LOBO_WRITE_ROOTS="$home_dir${current_dir:+:$current_dir}:$ANTARES_STATE" \
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
    deleted=0
    home_real=$(realpath -e -- "$home_dir" 2>/dev/null || printf '%s' "$home_dir")
    if [[ -s "$DELLIST" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            rp=$(realpath -e -- "$p" 2>/dev/null) \
                || { log "REFUSE unresolvable or missing: $p"; continue; }
            [[ "$(dirname "$rp")" == "$home_real" ]] \
                || { log "REFUSE out-of-scope path: $p (resolves to $rp)"; continue; }
            [[ "$rp" == *.md ]]            || { log "REFUSE not a .md: $p"; continue; }
            [[ "$(basename "$rp")" == "MEMORY.md" ]] && { log "REFUSE delete MEMORY.md"; continue; }
            [[ -f "$rp" ]]                 || { log "SKIP not a regular file: $p"; continue; }
            rm -f "$rp" && deleted=$((deleted+1)) && log "DELETED $rp"
        done < "$DELLIST"
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
