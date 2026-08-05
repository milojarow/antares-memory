#!/usr/bin/env bash
# PostToolUse hook — if a Write/Edit/MultiEdit touched a memory .md file
# (anywhere under ~/.claude/projects/<slug>/memory/), trigger an incremental
# reindex in the background so the new content is searchable by the
# UserPromptSubmit hook within the same session.
#
# Failsafe: any error → exit 0, never block the tool flow.

[[ -n "${CLAUDE_HEADLESS:-}" ]] && exit 0

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-reindex-auto.log"

# Cheap check ONLY: this hook declares a 5s timeout and the authoritative
# antares_venv_ready costs ~5.7s (it imports torch), so calling it here got the
# hook killed before it could fork — every single time.
if ! antares_venv_present; then
    exit 0
fi

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

[[ -z "$file_path" ]] && exit 0

# Match either store:
#   - $ANTARES_PROJECTS_DIR/<slug>/memory/...  (a project store)
#   - $(antares_home_memory_dir)/...           (the global store)
#
# The home branch is NOT redundant. When the global store is overridden — and on
# this install it is, to ~/.claude/memory-jarvis — it does not live under
# $ANTARES_PROJECTS_DIR at all, so the project pattern never matched it and this
# hook exited 0 for every global memory ever written. Measured: 0 triggers naming
# memory-jarvis since 2026-07-25 against 33 project triggers in the same window,
# while the `--scope home` branch below sat unreachable as dead code. The effect
# was exactly what this hook's docstring promises to prevent: a memory written
# mid-session stayed invisible to the UserPromptSubmit search until the NEXT
# session's SessionStart reindex picked it up.
home_dir="$(antares_home_memory_dir)"
case "$file_path" in
  "$ANTARES_PROJECTS_DIR"/*/memory/*) ;;
  "$home_dir"/*) ;;
  *) exit 0 ;;
esac

# Extract slug → reconstruct the original cwd to pass to the indexer.
# Path structure: $ANTARES_PROJECTS_DIR/<slug>/memory/<rest>
# A file in the global store has no slug; it is named explicitly for the log.
if [[ "$file_path" == "$home_dir"/* ]]; then
    slug="(home)"
else
    rest="${file_path#"$ANTARES_PROJECTS_DIR"/}"   # <slug>/memory/<rest>
    slug="${rest%%/memory/*}"
fi

# NO reverse slugify. There used to be one here ('-' back to '/'), and it cannot
# be made correct: slugify collapses EVERY non-alphanumeric character to '-', so a
# '-' in a slug may have been '/', '.', '_' or a literal '-'. `mosh-osc52` came
# back as `mosh/osc52`, and any dotdir came back wrong too — the reconstructed cwd
# then re-derived a DIFFERENT slug, so the indexer was pointed at a directory
# Claude Code never fills while the real store went unindexed. rc=0 throughout.
#
# The round-trip was never needed: this hook already holds the real path. It is
# passed straight through with --memory-dir.

# Skip MEMORY.md itself (always-loaded index, not indexed content).
[[ "$(basename "$file_path")" == "MEMORY.md" ]] && exit 0

# Skip backups, SQLite DB itself, non-md files.
case "$file_path" in
  *.bak*|*.db|*.db-*|*.db.*) exit 0 ;;
esac
[[ "$file_path" == *.md ]] || exit 0

# Pick the scope the indexer will actually accept for this slug.
#
# `--scope current` is NOT universal: get_scopes() dedupes current against home
# and returns an EMPTY list when the two resolve to the same dir. So on a machine
# whose working dir IS $HOME — the common case for an operator who lives in the
# shell — every trigger here resolved to nothing, printed "reindex done", and
# exited 0 having indexed zero files. A component that reports success without
# working is worse than one that fails, and this one hid behind the SessionStart
# reindex until that one broke too.
if [[ "$slug" == "(home)" ]]; then
    target_dir="$home_dir"
else
    target_dir="$ANTARES_PROJECTS_DIR/$slug/memory"
fi
if [[ "$target_dir" == "$home_dir" ]]; then
    scope_args=(--scope home)
else
    scope_args=(--memory-dir "$target_dir")
fi

# Async reindex of just the affected slug.
#
# Shares the SessionStart reindexer's lock so the two never write the same SQLite
# file at once. That reindexer used to be synchronous, so the race was narrow;
# detaching it (to stop it dying on its hook timeout) widened it.
# `-w`, not `-n`: this already runs in the background, so waiting for the other
# reindexer to finish costs nobody anything, whereas skipping would silently drop
# the indexing of a memory that was just written — the exact class of failure the
# detach was meant to end. Queued runs are cheap: the indexer only touches files
# whose mtime beats the stored one, so whoever gets there first does the work and
# the rest exit having found nothing stale.
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-reindex.lock"
{
  flock -w 300 9 || { printf '[%s] SKIP lock wait timed out\n' "$(date -Iseconds)" >>"$LOG"; exit 0; }
  printf '[%s] reindex slug=%s (%s) triggered by %s\n' \
    "$(date -Iseconds)" "$slug" "${scope_args[*]}" "$file_path" >>"$LOG"
  "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
    "${scope_args[@]}" >>"$LOG" 2>&1
  rc=$?   # capture BEFORE anything else runs: the $(date) below would clobber $?
  printf '[%s] reindex done slug=%s rc=%s\n' "$(date -Iseconds)" "$slug" "$rc" >>"$LOG"
} 9>>"$LOCK" </dev/null >/dev/null 2>&1 &
disown

exit 0
