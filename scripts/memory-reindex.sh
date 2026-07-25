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
needs_reindex() {
    local mdir="$1"
    local db="$mdir/.memory-index.db"
    [[ -d "$mdir" ]] || return 1
    if [[ ! -f "$db" ]]; then
        # No DB yet — reindex if there's at least one .md
        [[ -n "$(find "$mdir" -name '*.md' -print -quit 2>/dev/null)" ]]
        return $?
    fi
    [[ -n "$(find "$mdir" -name '*.md' -newer "$db" -print -quit 2>/dev/null)" ]]
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
    flock -n 9 || { antares_log "$LOG_FILE" "SKIP lock held (a reindex is already running)"; exit 0; }

    for scope in "${scopes[@]}"; do
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
