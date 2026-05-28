# scripts/lib/common.sh — shared env resolution for all antares-memory shell scripts.
#
# Source from each script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/common.sh
#   source "$SCRIPT_DIR/lib/common.sh"
#
# Reads these env vars (with sane defaults):
#   CLAUDE_MEMORY_HOME  — where memory .md files live (default ~/.claude/memory)
#   ANTARES_VENV        — Python venv with sentence-transformers (default ~/.local/share/antares-memory/venv)
#   ANTARES_STATE       — logs / locks / runtime state (default ~/.local/state/antares-memory)
#   ANTARES_MODEL       — sentence-transformers model name (default paraphrase-multilingual-MiniLM-L12-v2)
#
# Exports:
#   ANTARES_VENV_PY     — path to the venv's python3 binary
#   ANTARES_SCRIPTS_DIR — parent dir of this lib/ (where the scripts live)

export CLAUDE_MEMORY_HOME="${CLAUDE_MEMORY_HOME:-$HOME/.claude/memory}"
export ANTARES_VENV="${ANTARES_VENV:-$HOME/.local/share/antares-memory/venv}"
export ANTARES_STATE="${ANTARES_STATE:-$HOME/.local/state/antares-memory}"
export ANTARES_MODEL="${ANTARES_MODEL:-paraphrase-multilingual-MiniLM-L12-v2}"
export ANTARES_VENV_PY="$ANTARES_VENV/bin/python3"

# PreCompact extractor knobs — let the operator tune cost without editing the
# script (which lives in the plugin cache and gets overwritten on update).
export ANTARES_PRECOMPACT_BUDGET="${ANTARES_PRECOMPACT_BUDGET:-1.00}"
export ANTARES_PRECOMPACT_MODEL="${ANTARES_PRECOMPACT_MODEL:-sonnet}"
export ANTARES_PRECOMPACT_TIMEOUT="${ANTARES_PRECOMPACT_TIMEOUT:-300}"

# ANTARES_SCRIPTS_DIR is the directory holding the .sh / .py scripts. The
# library lives at <scripts>/lib/common.sh, so walk one level up.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANTARES_SCRIPTS_DIR="$(cd "$_lib_dir/.." && pwd)"

# Best-effort log dir (idempotent, never fatal).
mkdir -p "$ANTARES_STATE/logs" 2>/dev/null || true

# Boolean: does the venv exist and have sentence-transformers?
antares_venv_ready() {
    [[ -x "$ANTARES_VENV_PY" ]] \
        && "$ANTARES_VENV_PY" -c "import sentence_transformers" 2>/dev/null
}

# Stable log helper. Usage: antares_log <file> <msg...>
antares_log() {
    local log_file="$ANTARES_STATE/logs/$1"
    shift
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >>"$log_file" 2>/dev/null || true
}
