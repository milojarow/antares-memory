#!/usr/bin/env bash
# memory-reindex.sh — SessionStart hook: conditionally re-index memory embeddings.
# Reads cwd from stdin (SessionStart payload), reindexes the home + current
# slug dirs if any .md file is newer than the DB.
#
# THE INDEXER RUNS DETACHED, NOT IN THE FOREGROUND. This used to block the hook,
# and that is a permanent, self-reinforcing failure waiting to happen:
#
#   * a hook that overruns its declared timeout is killed;
#   * memory-index.py commits only at the END of a run, so a kill writes NOTHING
#     and the DB keeps its old mtime;
#   * the next session therefore retries the same too-big batch, is killed at the
#     same point, and the backlog is now larger than it was.
#
# Once the work stops fitting in the budget it never fits again. Found in
# production after 10 days of a frozen index: the incremental run needed 167s
# against a 60s hook timeout, and 45 memories written in that window were
# invisible to retrieval — a query quoting a fresh memory almost verbatim did not
# return it. It went unnoticed that long because this was the only script in the
# system that logged nothing at all, so a total failure and a clean no-op looked
# identical from the outside. Hence: background + flock + a log line per run.
#
# Same idiom as memory-reindex-if-touched.sh (background + disown). The flock is
# what keeps two sessions starting at once from stampeding the same SQLite file;
# it is taken INSIDE the subshell and released by the kernel, so a hard kill can
# never leave a wedged lock behind (see the lock note in the lobo launchers).
#
# Gracefully skips if the venv is not set up (operator hasn't run install yet).

[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="memory-reindex.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-reindex.lock"

if ! antares_venv_present; then
    antares_log "$LOG_FILE" "SKIP venv not installed ($ANTARES_VENV_PY) — run install.sh"
    echo '{}'
    exit 0
fi

# Read cwd from SessionStart hook payload (best-effort; defaults to $PWD).
input=""
if [[ -p /dev/stdin || ! -t 0 ]]; then
    input=$(cat)
fi
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

# Helper: is any .md newer than the DB?
#
# ONE process, and it stops at the first hit. The obvious shape — read every path
# and `stat` each one in a loop — forks once per memory, and this runs in the
# FOREGROUND of a hook on every single session start: measured at 6.2s on a store
# of ~320 memories, growing linearly with it. `find -newer` applies the same
# mtime comparison inside a single traversal, and `-quit` stops it the moment one
# file qualifies. Same answer, ~3 orders of magnitude cheaper.
#
# "Newer than the DB" answers only one of the three questions that matter, and the
# two it missed both end with the index describing a store that no longer exists.
needs_reindex() {
    local mdir="$1"
    local db="$mdir/.memory-index.db"
    [[ -d "$mdir" ]] || return 1
    if [[ ! -f "$db" ]]; then
        # No DB yet — reindex if there's at least one .md
        [[ -n "$(find "$mdir" -name '*.md' -print -quit 2>/dev/null)" ]]
        return $?
    fi

    # (1) A surviving file changed.
    [[ -n "$(find "$mdir" -name '*.md' -newer "$db" -print -quit 2>/dev/null)" ]] && return 0

    # (2) An entry was ADDED, DELETED or RENAMED. A directory's mtime moves for
    #     exactly that, and the old gate never looked at it — it only asked whether
    #     some SURVIVING file was newer than the DB, which after a deletion is no
    #     one. So a deleted memory kept its chunks and kept being returned.
    #
    #     That is not theoretical: the gardener is the component whose whole job is
    #     deleting memories, and the reindex it fires immediately afterwards came
    #     through this same gate. Measured end to end — delete a memory, run the
    #     gardener's exact call, then query: the deleted file came back as the TOP
    #     hit at 0.83 while not existing on disk, and the reindex had logged
    #     nothing at all because it was never launched. The indexer itself purges
    #     correctly (verified: same file, 0 chunks, once it is actually allowed to
    #     run); it was never the problem.
    #
    #     Ask the exact question — does every path the index still claims exist? —
    #     instead of an mtime proxy. The obvious proxy, "is the DIRECTORY newer
    #     than the DB", is WRONG HERE and was caught by the negative control: in
    #     WAL mode SQLite creates .memory-index.db-wal/-shm inside this very
    #     directory and REMOVES them when it closes cleanly, so the directory's
    #     mtime always lands after the DB's and the gate fires on every session
    #     start forever. One sqlite3 call plus a builtin -e per row costs ~10ms on
    #     a store of ~350 files; the shape this replaced forked `stat` per file and
    #     measured 6.2s.
    if command -v sqlite3 >/dev/null 2>&1; then
        local p
        while IFS= read -r p; do
            [[ -n "$p" && ! -e "$p" ]] && return 0
        done < <(sqlite3 -readonly "$db" \
                 "SELECT DISTINCT file_path FROM memory_chunks" 2>/dev/null)
    fi

    # (3) The CHUNKER changed. Bumping CHUNKER_VERSION is meant to re-embed every
    #     file, and memory-index.py does exactly that when it runs — but no .md is
    #     newer than the DB after a bump, so this gate said "nothing to do" and the
    #     bump silently applied to new files only, leaving a corpus split between
    #     two chunkings. Read from the source file so there is still ONE definition
    #     of the version. sqlite3 is a hard dependency of install.sh; if it is
    #     missing anyway, skip this check rather than reindex on every single start.
    if command -v sqlite3 >/dev/null 2>&1; then
        local want have
        want=$(grep -m1 -oE '^CHUNKER_VERSION[[:space:]]*=[[:space:]]*[0-9]+' \
               "$SCRIPT_DIR/memory-index.py" 2>/dev/null | grep -oE '[0-9]+$' || true)
        if [[ -n "$want" ]]; then
            have=$(sqlite3 -readonly "$db" \
                   "SELECT value FROM metadata WHERE key='chunker_version'" 2>/dev/null || true)
            [[ "$have" != "$want" ]] && return 0
        fi

        # (4) The index was written by a DIFFERENT EMBEDDING MODEL than the one that
        #     will query it. Every stored vector then lives in another space and
        #     cosine similarity against them is noise — not degraded, meaningless —
        #     while search still returns its top five and reports nothing wrong.
        #     The indexer has always stamped 'model_name' into the DB, and until now
        #     NOTHING read it: the one fact that identifies this failure was on disk
        #     the whole time, unused. It matters here specifically because this host
        #     runs a vocab-pruned copy of the model, so the value genuinely changes.
        have=$(sqlite3 -readonly "$db" \
               "SELECT value FROM metadata WHERE key='model_name'" 2>/dev/null || true)
        if [[ -n "$have" && "$have" != "$ANTARES_MODEL" ]]; then
            antares_log "$LOG_FILE" "MODEL CHANGED for $mdir: index built with '$have', now using '$ANTARES_MODEL' — full re-embed"
            return 0
        fi
    fi

    return 1
}

home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"

# Decide in the FOREGROUND (stat comparisons, microseconds) so an up-to-date
# index costs nothing and never forks.
scopes=()
needs_reindex "$home_dir" && scopes+=("home")
if [[ "$current_dir" != "$home_dir" ]] && needs_reindex "$current_dir"; then
    scopes+=("current")
fi

if (( ${#scopes[@]} == 0 )); then
    echo '{}'
    exit 0
fi

# Everything past this point is detached: the embedding work takes as long as it
# takes (minutes, on a big backlog) and MUST outlive the hook's timeout.
(
    # WAIT for the lock, don't abandon the work. This used to be `flock -n`, while
    # its twin memory-reindex-if-touched.sh waits up to 300s — the same lock, two
    # opposite policies. Bailing loses real work: two sessions starting at once
    # index DIFFERENT scopes (each one's own project slug), so the loser dropped
    # its project's reindex entirely and that store stayed stale for the whole
    # session. The gardener's post-deletion reindex comes through here too, so the
    # loser also skipped purging just-deleted memories from the index.
    #
    # Waiting is free: everything here is already detached from the hook.
    flock -w 300 9 || { antares_log "$LOG_FILE" "SKIP lock wait timed out after 300s"; exit 0; }

    for scope in "${scopes[@]}"; do
        # Re-decide UNDER the lock. The decision above was made before waiting, and
        # the run we waited behind may have already done this exact scope — same
        # reason the chronicle launcher re-reads its watermark once it holds its own
        # lock. Without this, waiting converts a wasted skip into a wasted reindex.
        case "$scope" in
            home)    scope_dir="$home_dir" ;;
            current) scope_dir="$current_dir" ;;
        esac
        if ! needs_reindex "$scope_dir"; then
            antares_log "$LOG_FILE" "SKIP scope=$scope — already fresh (another run did it while we waited)"
            continue
        fi
        start=$SECONDS
        if [[ "$scope" == "home" ]]; then
            "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope home >/dev/null 2>&1
        else
            "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
                --scope current --cwd "$cwd" >/dev/null 2>&1
        fi
        rc=$?
        antares_log "$LOG_FILE" "REINDEX scope=$scope rc=$rc took=$((SECONDS - start))s"
    done
) 9>>"$LOCK" >/dev/null 2>&1 &
disown

echo '{}'
exit 0
