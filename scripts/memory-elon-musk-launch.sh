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
PATHS=(memory-jarvis projects lobo-state)

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG" 2>/dev/null || true; }

[[ -d "$REPO/.git" ]] || { log "SKIP $REPO is not a git repo"; echo '{}'; exit 0; }

# Mirror the lobos' persistent memories into the backed-up tree. These are what
# the gardener and curator have LEARNED about the operator (88 KB and 8 KB here)
# and they lived only in $ANTARES_STATE, which nothing backs up: lose the disk and
# both lobos start over with no idea what the operator keeps. Kept OUTSIDE the
# memory dirs on purpose — they are lobo state, not memories, and must not be
# indexed or injected as if they were.
#
# In the FOREGROUND, before the pre-check below: the mirror is what makes these
# files show up as pending, so running it after the "nothing to back up" exit
# meant it never ran at all. Two small files, `cp -u`, so the cost is noise.
#
# It also has to run BEFORE the existence filter below, because it is what brings
# lobo-state INTO existence. Filtering first meant lobo-state was dropped from
# PATHS as "absent", created moments later, and then never staged by any run —
# the mirror worked and the backup silently ignored its output. Order matters
# here: a self-creating path cannot be tested for existence before its creator.
if compgen -G "$ANTARES_STATE"/*.md >/dev/null 2>&1; then
    mkdir -p "$REPO/lobo-state" 2>/dev/null \
        && cp -u "$ANTARES_STATE"/*.md "$REPO/lobo-state/" 2>/dev/null || true
fi

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

# Report memory stores this lobo does NOT cover. Legacy walk-up stores live at
# <project>/.claude/memory/ — outside this repo, and typically gitignored by the
# project that hosts them, so nothing backs them up at all. Naming them in the log
# is the whole point: a backup that silently covers less than you think is the
# failure this lobo exists to prevent, and it should not commit that failure
# itself. Cheap (one find, depth-limited) and reported once per run.
# `|| true` is load-bearing, not defensive noise. `find` exits 1 when the root does
# not exist, `2>/dev/null` hides the message but not the status, `pipefail` carries
# it through `head`, and the ERR trap at the top of this file turns that into
# `echo '{}'; exit 0`. On a machine with no ~/projects — most of them — this
# REPORTING line killed the backup lobo before it committed anything, and it did so
# in the trap's own voice: a clean exit, no log line, nothing to notice. A
# diagnostic that reports on a directory's absence must not itself die of it.
uncovered=$(find "$HOME/projects" -maxdepth 3 -type d -path '*/.claude/memory' 2>/dev/null | head -5 || true)
if [[ -n "$uncovered" ]]; then
    log "UNCOVERED walk-up store(s) outside this repo, not backed up here: $(printf '%s ' $uncovered)"
fi

# Cheap pre-check in the foreground: nothing to do → don't even fork.
# (SessionStart hooks are not on the 1.5s SessionEnd budget, but this hook
# declares its own timeout anyway — see the gotcha in `man memories`.)
pending=$(git -C "$REPO" status --porcelain -- "${PATHS[@]}" 2>/dev/null | grep -c . || true)
# An earlier run may have committed and failed to push (offline, unreachable
# remote). Its own comment promised "the next session start pushes the
# accumulated commits", but the early exit above returned first whenever no NEW
# memory had appeared since — so a backlog could sit committed-but-unpushed
# indefinitely, with the log cheerfully reporting "nothing to back up" while the
# remote fell further behind. Local commits are not a backup.
unpushed=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
if (( pending == 0 && unpushed == 0 )); then
    log "OK nothing to back up"
    echo '{}'; exit 0
fi

(
    flock -n 9 || { log "SKIP lock held"; exit 0; }

    cd "$REPO" || exit 0

    # Stage ONLY the memory paths. Explicit, so operator WIP elsewhere in the
    # repo is never swept into a commit it didn't ask for.
    git add -- "${PATHS[@]}" 2>/dev/null || { log "FAILED git add"; exit 0; }

    # SCRUB GATE — refuse to commit a diff that carries a live secret.
    #
    # This exists because it already happened: on 2026-07-25 a capture lobo
    # transcribed a backup passphrase and four live mailbox passwords verbatim into
    # session journals, and this lobo pushed them. A pre-push scan HAD been run and
    # reported clean — it looked for the `key: value` shape of a config file, and a
    # secret written in PROSE inside a narrative matches none of that. The lesson is
    # in the ordering below: pattern matching is the SECOND layer, not the first.
    #
    # Layer 1, VALUE matching, is the one that would have caught it. Read the actual
    # secret material this machine holds and look for those exact strings in the
    # diff. No heuristic, no entropy guessing, no false positives — if the literal
    # value of a credential appears in something about to leave the machine, that is
    # not a maybe.
    #
    # ANTARES_SECRET_SOURCES: colon-separated files/dirs holding credential material.
    # Nothing is read from them except to compare; values never reach the log.
    scrub_hits=""
    diff_file=$(mktemp) || diff_file=""
    if [[ -n "$diff_file" ]]; then
        git diff --cached -- "${PATHS[@]}" > "$diff_file" 2>/dev/null || true

        sources="${ANTARES_SECRET_SOURCES:-$HOME/.secrets:$HOME/.config}"
        while IFS= read -r sf; do
            [[ -f "$sf" ]] || continue
            # whole-file values (a passphrase file) and KEY=VALUE lines alike
            while IFS= read -r v; do
                v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
                (( ${#v} >= 12 )) || continue
                (( ${#v} <= 200 )) || continue
                if grep -qF -- "$v" "$diff_file" 2>/dev/null; then
                    scrub_hits+="  value from ${sf/#$HOME/\~} appears in the staged diff"$'\n'
                    break
                fi
            done < <(
                { cat "$sf"; sed -n 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=//p' "$sf"; } 2>/dev/null \
                  | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^#' | grep -v '^$'
            )
        done < <(
            IFS=':' read -ra _sd <<< "$sources"
            for d in "${_sd[@]}"; do
                [[ -e "$d" ]] || continue
                find "$d" -maxdepth 3 -type f -size -64k 2>/dev/null
            done
        )

        # Layer 2: shapes that are secrets no matter where they came from.
        if grep -qEi -- '(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}' "$diff_file" 2>/dev/null; then
            scrub_hits+="  a token/private-key shape appears in the staged diff"$'\n'
        fi
        rm -f "$diff_file"
    fi

    if [[ -n "$scrub_hits" ]]; then
        # Loud and blocking. Unstage so nothing is left armed for the next run, and
        # do NOT name the file or print the value — the log is backed up too.
        git reset -q -- "${PATHS[@]}" 2>/dev/null || true
        log "REFUSING TO COMMIT — scrub gate tripped:"
        printf '%s' "$scrub_hits" | while IFS= read -r l; do [[ -n "$l" ]] && log "$l"; done
        log "  nothing was committed or pushed. Redact the offending memory/journal by hand, then the next session start will back up normally."
        exit 0
    fi

    staged=$(git diff --cached --numstat -- "${PATHS[@]}" 2>/dev/null | wc -l)
    if (( staged == 0 )); then
        # Nothing new to commit. That is NOT a reason to leave earlier commits
        # unpushed — this is exactly the case that let a backlog sit local
        # forever. Fall through to the push instead of exiting.
        if (( unpushed == 0 )); then
            log "OK nothing staged (all ignored?)"
            exit 0
        fi
        log "no new memories, but $unpushed commit(s) unpushed — pushing"
    else

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

    # Pathspec on the commit, not just on the add: `git commit` without one writes
    # the WHOLE index, so anything the operator had staged elsewhere in this repo
    # would be swept into an automated commit they never asked for. Staging
    # carefully and then committing everything defeats the point.
    # Pathspec LAST: everything after `--` is a path, so putting it before the -m
    # flags makes git read the commit messages as filenames ("did not match any
    # file(s) known to git"). Caught by the failsafe, but only because there is one.
    if ! git commit -q -m "memory: $summary ($(date +%F))" \
                    -m "Automatic backup of the memory base by the elon-musk lobo (SessionStart). Content written by the capture lobos; this only preserves it." \
                    -- "${PATHS[@]}" 2>>"$LOG"; then
        log "FAILED git commit"
        exit 0
    fi
    head=$(git log --oneline -1)
    log "COMMIT $head"

    fi

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
