# scripts/lib/common.sh — shared env resolution for all antares-memory shell scripts.
#
# Source from each script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/common.sh
#   source "$SCRIPT_DIR/lib/common.sh"
#
# Storage model: Claude Code's native convention.
#   ~/.claude/projects/<slugify(cwd)>/memory/   ← auto-loaded MEMORY.md, per cwd
#   ~/.claude/projects/<slugify($HOME)>/memory/ ← "global" (when cwd == $HOME)
#
# The skill mirrors this convention so the operator never needs `@`-imports in
# CLAUDE.md — Claude Code already loads MEMORY.md from the cwd's slug dir.
#
# Reads these env vars (with sane defaults):
#   ANTARES_VENV        — Python venv with sentence-transformers
#                          (default ~/.local/share/antares-memory/venv)
#   ANTARES_STATE       — logs / locks / runtime state
#                          (default ~/.local/state/antares-memory)
#   ANTARES_MODEL       — sentence-transformers model name
#                          (default paraphrase-multilingual-MiniLM-L12-v2)
#   (per-lobo knobs ANTARES_CRONISTA_*/DISTILLER_*/GARDENER_*/CURATOR_* are read
#    directly by each lobo's .mjs/launcher with inline defaults — not exported here.)

export ANTARES_VENV="${ANTARES_VENV:-$HOME/.local/share/antares-memory/venv}"
export ANTARES_STATE="${ANTARES_STATE:-$HOME/.local/state/antares-memory}"
export ANTARES_MODEL="${ANTARES_MODEL:-paraphrase-multilingual-MiniLM-L12-v2}"
export ANTARES_VENV_PY="$ANTARES_VENV/bin/python3"

# Root of all slug-based memory dirs.
export ANTARES_PROJECTS_DIR="$HOME/.claude/projects"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANTARES_SCRIPTS_DIR="$(cd "$_lib_dir/.." && pwd)"

mkdir -p "$ANTARES_STATE/logs" 2>/dev/null || true

# slugify <path> — replicate Claude Code's cwd → slug convention.
# Empirically: '/' → '-'. Edge cases (paths inside ~/.claude/ itself) may not
# round-trip perfectly, but those are not normal operator working dirs.
antares_slugify() {
    printf '%s' "$1" | tr '/' '-'
}

# memory dir for a given cwd. Does NOT create — pure path computation.
antares_memory_dir_for() {
    local cwd="${1:-$PWD}"
    printf '%s/%s/memory' "$ANTARES_PROJECTS_DIR" "$(antares_slugify "$cwd")"
}

# the "home" memory dir — used as global by convention (cwd=$HOME slug).
antares_home_memory_dir() {
    antares_memory_dir_for "$HOME"
}

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
