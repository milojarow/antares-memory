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

# Lock: one gardener at a time.
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP lock held (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi

home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"
changelog="$home_dir/.gardener-changelog.md"
today=$(date +%Y-%m-%d)

build_digest() {
    local dir="$1" f b d
    shopt -s nullglob
    for f in "$dir"/*.md; do
        b=$(basename "$f")
        [[ "$b" == "MEMORY.md" ]] && continue
        d=$(grep -m1 '^description:' "$f" 2>/dev/null \
            | sed -E 's/^description:[[:space:]]*//; s/^"//; s/"$//')
        [[ -z "$d" ]] && d="(no description)"
        printf -- '- %s: %s\n' "$f" "$d"
    done
    shopt -u nullglob
}

digest="$(build_digest "$home_dir")"
if [[ "$current_dir" != "$home_dir" ]]; then
    cur="$(build_digest "$current_dir")"
    [[ -n "$cur" ]] && digest="$digest
$cur"
fi
n_mem=$(printf '%s' "$digest" | grep -c '^- ' || true)
prefs_body=$(cat "$PREFS" 2>/dev/null || echo "(no preferences recorded yet — be extra conservative; record what the operator keeps to your memory file.)")

: > "$DELLIST"  # fresh empty deletions list for this run

task="Today is $today. Keep the base clean by ACTING (merge duplicates, remove obsolete). Do NOT leave notes.

== YOUR MEMORY (operator preferences — read FIRST; update at $PREFS) ==
$prefs_body

== ALL MEMORIES ($n_mem total — full-path: description) ==
$digest

Merge near-duplicates into the best survivor (Edit it). Write the COMPLETE list of redundant/obsolete file paths to $DELLIST (one per line, single Write — the launcher validates + deletes them). Log every action to $changelog. NEVER touch MEMORY.md. Conservative: when unsure, KEEP. Update your memory at $PREFS if you learned what the operator keeps."

log "LAUNCH gardener (background) cwd=$cwd memories=$n_mem model=${ANTARES_GARDENER_MODEL:-opus}"
(
    trap 'rm -f "$LOCK"' EXIT
    export CLAUDE_HEADLESS=1
    antares_link_sdk "$SCRIPT_DIR/../agents-sdk" || log "SDK not installed — run /antares-memory:install (lobo fails rc=1)"

    # FULL backup of the base before the gardener can merge/flag anything.
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    tar czf "$BACKUP_DIR/base.$(date +%Y%m%d-%H%M%S).tar.gz" -C "$home_dir" . 2>/dev/null || true
    ls -1t "$BACKUP_DIR"/base.*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f  # keep last 5

    out=$(printf '%s' "$task" | timeout "${ANTARES_GARDENER_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/gardener.mjs" 2>>"$LOG")
    rc=$?
    # Stamp the gate ONLY on success — a failed run (rc!=0) must NOT block the 24h gate,
    # or one failure locks the gardener out for ~24h without ever having run. Retry next close.
    if (( rc == 0 )); then echo "$now" > "$STAMP"; else log "gardener rc=$rc — gate NOT stamped, retries next close"; fi

    # Execute the lobo's deletions list — VALIDATED: a .md inside home_dir, never MEMORY.md.
    deleted=0
    if [[ -s "$DELLIST" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            case "$p" in
                "$home_dir"/*.md)
                    bn=$(basename "$p")
                    [[ "$bn" == "MEMORY.md" ]] && { log "REFUSE delete MEMORY.md"; continue; }
                    [[ -f "$p" ]] || { log "SKIP missing $p"; continue; }
                    rm -f "$p" && deleted=$((deleted+1)) && log "DELETED $p"
                    ;;
                *) log "REFUSE out-of-scope path: $p" ;;
            esac
        done < "$DELLIST"
    fi

    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1000)
    log "DONE rc=$rc deleted=$deleted result=$result"

    # Reindex if the base changed (deleted files must leave the search index).
    if (( deleted > 0 )); then
        bash "$SCRIPT_DIR/memory-reindex.sh" >/dev/null 2>&1 || true
    fi
) >/dev/null 2>&1 &
disown

exit 0
