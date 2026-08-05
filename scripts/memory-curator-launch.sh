#!/usr/bin/env bash
# SessionEnd hook — fire-and-forget launcher for the "index-curator" lobo.
# The operator delegated index curation: the curator DECIDES and EDITS MEMORY.md
# itself (opus, high effort). This launcher gives it three things the bare prompt
# can't: (1) a DIGEST of the base (so it never reads 150 bodies), (2) its
# PERSISTENT MEMORY of operator preferences (read in, updated out), and (3) a
# BACKUP of MEMORY.md taken before every run — the index is always-on, so any
# auto-edit must be revertible. Guards: gate ~7d, lock, background+disown.
#
# Failsafe: ANY error → exit 0.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-curator.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-curator.lock"
STAMP="$ANTARES_STATE/curator-last-run"
PREFS="$ANTARES_STATE/curator-memory.md"          # persistent memory (operator preferences)
BACKUP_DIR="$ANTARES_STATE/memory-md-backups"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

now=$(date +%s)

# Gate: at most once per ~7 days.
if [[ -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( now - last < 604800 )); then
        log "SKIP gate: last run $(( now - last ))s ago (<7d)"
        exit 0
    fi
fi

# Lock: one curator at a time. Acquired with flock INSIDE the background subshell
# (see below), never as a lock FILE here: a pid-in-a-file lock is only released by
# a trap, so a lobo killed hard (SIGKILL, OOM, power loss) leaves the file behind
# and every later session SKIPs forever — silently, since a wedged lobo looks
# exactly like a busy one in the log. The kernel releases an flock unconditionally.
# Same pattern as skill-keeper-launch.sh.

home_dir="$(antares_home_memory_dir)"
mem_index="$home_dir/MEMORY.md"
changelog="$home_dir/.index-changelog.md"
# The lobo writes ONE RUN here; the launcher appends it to the permanent
# changelog. Handing it $changelog directly — with a prompt that said "overwrite
# the changelog path" — put the only audit trail of MEMORY.md one mis-aimed Write
# away from gone, and the three entries it holds survived only because the model
# declined to follow its own instruction. MEMORY.md itself has rotated backups
# below; the changelog has none and reconstructs from nowhere.
# Same fix the gardener already carries (memory-gardener-launch.sh:37).
CL_ENTRY="$ANTARES_STATE/curator-changelog-entry.md"
today=$(date +%Y-%m-%d)

# Digest: filename + frontmatter description of every memory (NOT bodies).
# Filenames as labels — the curator writes index entries, it doesn't touch files.
digest="$(antares_build_digest "$home_dir")"
n_mem=$(printf '%s' "$digest" | grep -c '^- ' || true)

index_body=$(cat "$mem_index" 2>/dev/null || echo "(MEMORY.md absent)")
prefs_body=$(cat "$PREFS" 2>/dev/null || echo "(no preferences recorded yet — infer the operator's taste from the CURRENT INDEX they hand-curated, and record what you learn to your memory file.)")

task="Today is $today. You own the always-on index. Decide and APPLY.

== YOUR MEMORY (operator preferences + your past decisions — read FIRST; update it at $PREFS) ==
$prefs_body

== CURRENT INDEX ($mem_index — edit this file in place) ==
$index_body

== ALL MEMORIES ($n_mem total — filename: description) ==
$digest

Apply promotions/demotions directly to $mem_index per your policy (conservative on removal — when unsure, KEEP). Write THIS RUN's changelog entry — what you changed and why — to $CL_ENTRY (single Write, just this run; the launcher appends it to the permanent changelog. Do NOT open $changelog yourself). Update your memory at $PREFS if you learned anything. The memory files live in $home_dir."

log "LAUNCH index-curator (background) cwd=$cwd memories=$n_mem model=${ANTARES_CURATOR_MODEL:-opus}"
(
    flock -n 9 || { log "SKIP lock held"; exit 0; }
    export CLAUDE_HEADLESS=1
    antares_link_sdk "$SCRIPT_DIR/../agents-sdk" || log "SDK not installed — run install.sh (lobo fails rc=1)"
    # Backup MEMORY.md before the curator can touch it (always-on file → revertible).
    if [[ -f "$mem_index" ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
        cp "$mem_index" "$BACKUP_DIR/MEMORY.md.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        # Keep only the last 10 backups.
        ls -1t "$BACKUP_DIR"/MEMORY.md.* 2>/dev/null | tail -n +11 | xargs -r rm -f
    fi
    # Truncate the entry file INSIDE the lock: a stale entry from a previous run
    # would otherwise be appended a second time.
    : > "$CL_ENTRY"
    antares_lobo_env "$home_dir:$ANTARES_STATE"
    out=$(printf '%s' "$task" | env -i "${ANTARES_LOBO_ENV[@]}" \
        timeout "${ANTARES_CURATOR_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/index-curator.mjs" 2>>"$LOG")
    rc=$?
    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1000)
    # Append this run's entry. The permanent changelog is only ever appended to,
    # and the append is verified by size so a silent failure cannot pass as done.
    if [[ -s "$CL_ENTRY" ]]; then
        cl_before=$(stat -c %s "$changelog" 2>/dev/null || echo 0)
        { printf '\n'; cat "$CL_ENTRY"; printf '\n'; } >> "$changelog" 2>>"$LOG"
        cl_after=$(stat -c %s "$changelog" 2>/dev/null || echo 0)
        if (( cl_after > cl_before )); then
            log "CHANGELOG appended $(( cl_after - cl_before ))B (${cl_before}B -> ${cl_after}B)"
        else
            log "CHANGELOG append FAILED (${cl_before}B -> ${cl_after}B) — entry kept at $CL_ENTRY"
        fi
    fi
    # Stamp the gate ONLY on success — a failed run (rc!=0) must NOT block the 7d gate; retry next close.
    if (( rc == 0 )); then echo "$now" > "$STAMP"; else log "curator rc=$rc — gate NOT stamped, retries next close"; fi
    log "DONE rc=$rc result=$result"
) 9>>"$LOCK" >/dev/null 2>&1 &
disown

exit 0
