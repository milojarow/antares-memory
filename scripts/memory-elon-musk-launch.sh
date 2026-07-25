#!/usr/bin/env bash
# memory-elon-musk-launch.sh — SessionStart hook: back the memory base up to git.
#
# THE LOBO "ELON MUSK" — named by the operator (2026-07-24): the one who
# launches things to the remote, the way Elon launches rockets. It is the only
# member of the pack that pushes; every other lobo only writes locally.
#
# THE GAP IT CLOSES: the lobos write memories and journals all day, and nothing
# ever committed them. An audit on one install found 51 memories that had NEVER
# entered git — they existed on a single disk. The search index is rebuildable;
# the memories are not.
#
# ONE REPO PER MACHINE. It pushes wherever `~/.claude` already points — the
# remote is a property of that clone, not of this script. Every machine backs up
# to its OWN private repo; never point two machines at the same one, or their
# memory stores (which are per-machine by design) would fight over one history.
#
# NO MODEL CALL, on purpose. Committing files is deterministic work with no
# judgment in it; a lobo here would burn a model call on every session start and
# add a hallucination surface to a git operation. Judgment stays in the session
# and in the event-driven lobos ("deterministic reflexes in bash" — man memories).
#
# WHY SessionStart AND NOT SessionEnd: the capture lobos (cronista → destilador,
# gardener, curator) are themselves fire-and-forget at SessionEnd and keep writing
# for a minute or two after the session closes. Backing up at that moment races
# them and would snapshot half-written files. By the next SessionStart everything
# from prior sessions has settled. (If a previous session's destilador is still
# running, worst case a memory lands one commit later — never lost.)
#
# SCOPE: memory data only — the memory base, the per-cwd stores, journals.
# Never `git add -A`: this repo also holds persona files, settings and plugin
# state that the operator edits deliberately and commits with intent.
#
# Failsafe: ANY error → exit 0. Never block a session from starting.

# Re-entrancy guard: skip when invoked from a headless sub-claude.
[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

trap 'echo "{}"; exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPO="$HOME/.claude"
LOG="$ANTARES_STATE/logs/memory-elon-musk.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-elon-musk.lock"
# Paths that hold memory DATA. Everything else in this repo is operator-authored.
PATHS=(memory-jarvis projects)

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG" 2>/dev/null || true; }

[[ -d "$REPO/.git" ]] || { log "SKIP $REPO is not a git repo"; echo '{}'; exit 0; }

# Keep only the paths THIS machine actually has. `git add` aborts on the first
# pathspec that matches nothing — verified: `git add -- missing existing` prints
# "fatal: pathspec 'missing' did not match any files" and stages ZERO files, so
# one legacy path absent means no backup at all, forever, on that machine. The
# pre-check below would still pass (`git status --porcelain` tolerates unmatched
# pathspecs), so the only symptom is a "FAILED git add" line in a log nobody
# reads — exactly the silent-failure shape this lobo exists to prevent.
present=()
for p in "${PATHS[@]}"; do
    [[ -e "$REPO/$p" ]] && present+=("$p")
done
if (( ${#present[@]} == 0 )); then
    log "SKIP none of the memory paths exist in $REPO (${PATHS[*]})"
    echo '{}'; exit 0
fi
PATHS=("${present[@]}")

# Cheap pre-check in the foreground: nothing to do → don't even fork.
# (SessionStart hooks are not on the 1.5s SessionEnd budget, but this hook
# declares its own timeout anyway — see the gotcha in `man memories`.)
pending=$(git -C "$REPO" status --porcelain -- "${PATHS[@]}" 2>/dev/null | grep -c . || true)
if (( pending == 0 )); then
    log "OK nothing to back up"
    echo '{}'; exit 0
fi

(
    flock -n 9 || { log "SKIP lock held"; exit 0; }

    cd "$REPO" || exit 0

    # Stage ONLY the memory paths. Explicit, so operator WIP elsewhere in the
    # repo is never swept into a commit it didn't ask for.
    git add -- "${PATHS[@]}" 2>/dev/null || { log "FAILED git add"; exit 0; }

    staged=$(git diff --cached --numstat -- "${PATHS[@]}" 2>/dev/null | wc -l)
    if (( staged == 0 )); then
        log "OK nothing staged (all ignored?)"
        exit 0
    fi

    # Deterministic summary — counts, not prose. Journals are noisy by nature and
    # get counted separately so the memory numbers stay meaningful.
    new=$(git diff --cached --name-status -- "${PATHS[@]}" | awk '$1=="A" && $2 !~ /\/journal\//' | wc -l)
    mod=$(git diff --cached --name-status -- "${PATHS[@]}" | awk '$1=="M" && $2 !~ /\/journal\//' | wc -l)
    del=$(git diff --cached --name-status -- "${PATHS[@]}" | awk '$1=="D" && $2 !~ /\/journal\//' | wc -l)
    jrn=$(git diff --cached --name-only -- "${PATHS[@]}" | grep -c '/journal/' || true)

    parts=()
    (( new )) && parts+=("$new new")
    (( mod )) && parts+=("$mod updated")
    (( del )) && parts+=("$del removed")
    (( jrn )) && parts+=("$jrn journal")
    # Join with ", " — ${arr[*]} only ever uses the FIRST char of IFS, so a
    # literal ", " there silently drops the space.
    summary=$(printf '%s, ' "${parts[@]}"); summary="${summary%, }"
    [[ -z "$summary" ]] && summary="$staged files"

    if ! git commit -q -m "memory: $summary ($(date +%F))" \
                    -m "Automatic backup of the memory base by the elon-musk lobo (SessionStart). Content written by the capture lobos; this only preserves it." 2>>"$LOG"; then
        log "FAILED git commit"
        exit 0
    fi
    head=$(git log --oneline -1)
    log "COMMIT $head"

    # Push is best-effort: offline or unreachable just leaves it committed, and
    # the next session start pushes the accumulated commits. NEVER pull/rebase/
    # force — a diverged remote means another machine wrote too, and reconciling
    # that is the operator's call (same discipline as skill-keeper).
    if git push -q origin HEAD 2>>"$LOG"; then
        log "PUSHED -> $(git rev-parse --short HEAD)"
    else
        ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo '?')
        if git rev-list --count HEAD..@{u} 2>/dev/null | grep -qv '^0$'; then
            log "DIVERGED remote has commits we don't — needs operator reconcile (local ahead=$ahead)"
        else
            log "PUSH failed (offline?) — $ahead commit(s) queued, retries next session"
        fi
    fi
) 9>>"$LOCK" >/dev/null 2>&1 &
disown

echo '{}'
exit 0
