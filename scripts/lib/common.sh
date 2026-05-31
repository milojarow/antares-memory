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

# Stable home for the Agent SDK's node_modules — installed ONCE (like the venv
# above), so it survives plugin updates; the per-version plugin cache does not.
export ANTARES_SDK_DIR="${ANTARES_SDK_DIR:-$HOME/.local/share/antares-memory/sdk}"

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

# Make the SDK resolvable from the .mjs lobos living in the (per-version) plugin
# cache: symlink their agents-sdk/node_modules to the stable install. ESM ignores
# NODE_PATH, so a real node_modules in the resolution path is required — a symlink
# suffices and is recreated for free after every plugin update. Returns nonzero if
# the stable SDK isn't installed yet (run install.sh / npm ci in $ANTARES_SDK_DIR).
antares_link_sdk() {
    local sdk_parent="$1"   # the agents-sdk dir that holds the .mjs lobos
    [[ -e "$sdk_parent/node_modules" ]] && return 0           # already there (real dir or good link)
    [[ -d "$ANTARES_SDK_DIR/node_modules" ]] || return 1      # stable SDK not installed yet
    ln -sfn "$ANTARES_SDK_DIR/node_modules" "$sdk_parent/node_modules" 2>/dev/null
}

# Stable log helper. Usage: antares_log <file> <msg...>
antares_log() {
    local log_file="$ANTARES_STATE/logs/$1"
    shift
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >>"$log_file" 2>/dev/null || true
}
