#!/usr/bin/env bash
# memory-scope-guard.sh — PreToolUse(Write|Edit) hook.
# When Claude writes a PROJECT-scoped memory file, inject a scope-check
# reminder: scope is decided per FACT, never inherited from the file being
# edited. Transversal knowledge belongs in the GLOBAL memory dir (the HOME
# scope), else it is invisible to every other cwd's sessions.
# Born 2026-07-10: a cross-cutting lesson was appended to a project memory
# file and the global/project decision silently never happened.
# Deterministic by design: this is a reflex, not a judgment — the judgment
# stays with the writing session, which holds the fact's full context. Never
# put a lobo here: a headless call per Write/Edit is the cascade anti-pattern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

payload=$(cat)
fp=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || exit 0
[[ -z "$fp" ]] && exit 0

global_dir="$(antares_home_memory_dir)"

# Writing INTO the global scope needs no reminder — it IS the destination.
[[ "$fp" == "$global_dir"/* ]] && exit 0

# Project memory locations: the slug convention (~/.claude/projects/<slug>/memory/)
# plus the legacy repo-level .claude/memory/ layout.
if [[ "$fp" =~ \.claude/(projects/[^/]+/)?memory/ ]]; then
  jq -n --arg ctx "SCOPE-CHECK (memory-scope-guard): writing to PROJECT-scoped memory ($fp). Decide scope PER FACT, not per file — appending to or updating a project file does NOT decide the new fact's scope. If any part of what you are saving is transversal (platform/API/policy/tool behavior; phrases like 'any future app/project'; anything useful outside this repo), ALSO write it to the GLOBAL memory dir ($global_dir) as its own memory plus an index line in its MEMORY.md, and leave the project file holding only the local detail or a pointer." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$ctx}}'
fi
exit 0
