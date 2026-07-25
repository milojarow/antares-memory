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

# Match: $ANTARES_PROJECTS_DIR/<slug>/memory/...
# That means the parent of the file is somewhere under a slug's memory/ dir.
case "$file_path" in
  "$ANTARES_PROJECTS_DIR"/*/memory/*) ;;
  *) exit 0 ;;
esac

# Extract slug → reconstruct the original cwd to pass to the indexer.
# Path structure: $ANTARES_PROJECTS_DIR/<slug>/memory/<rest>
rest="${file_path#"$ANTARES_PROJECTS_DIR"/}"   # <slug>/memory/<rest>
slug="${rest%%/memory/*}"

# Reverse slugify: '-' → '/'. Lossy at edges; for our use the recovered cwd
# only needs to make memory_dir_for(cwd) match the original slug, which the
# indexer recomputes anyway. We just need ANY cwd that slugifies to <slug>.
cwd="/${slug//-/'/'}"
cwd="${cwd//\/\//\/}"   # collapse accidental double slashes

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
target_dir="$ANTARES_PROJECTS_DIR/$slug/memory"
if [[ "$target_dir" == "$(antares_home_memory_dir)" ]]; then
    scope_args=(--scope home)
else
    scope_args=(--scope current --cwd "$cwd")
fi

# Async reindex of just the affected slug.
{
  printf '[%s] reindex slug=%s (%s) triggered by %s\n' \
    "$(date -Iseconds)" "$slug" "${scope_args[*]}" "$file_path" >>"$LOG"
  "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
    "${scope_args[@]}" >>"$LOG" 2>&1
  rc=$?   # capture BEFORE anything else runs: the $(date) below would clobber $?
  printf '[%s] reindex done slug=%s rc=%s\n' "$(date -Iseconds)" "$slug" "$rc" >>"$LOG"
} </dev/null >/dev/null 2>&1 &
disown

exit 0
