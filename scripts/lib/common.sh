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
# antares-memory mirrors this convention so the operator never needs `@`-imports in
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
# above), so it survives re-deploys; the deploy dir only carries a symlink to it.
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

# Make the SDK resolvable from the .mjs lobos living in the
# deploy dirs: symlink their agents-sdk/node_modules to the stable install. ESM ignores
# NODE_PATH, so a real node_modules in the resolution path is required — a symlink
# suffices and is recreated for free after every re-deploy. Returns nonzero if
# the stable SDK isn't installed yet (run install.sh / npm ci in $ANTARES_SDK_DIR).
antares_link_sdk() {
    local sdk_parent="$1"   # the agents-sdk dir that holds the .mjs lobos
    [[ -e "$sdk_parent/node_modules" ]] && return 0           # already there (real dir or good link)
    [[ -d "$ANTARES_SDK_DIR/node_modules" ]] || return 1      # stable SDK not installed yet
    ln -sfn "$ANTARES_SDK_DIR/node_modules" "$sdk_parent/node_modules" 2>/dev/null
}

# Digest of a memory dir — one "- <label>: <description>" line per memory
# (frontmatter only, never bodies). MEMORY.md is excluded; a file with no
# description line falls back to "(no description)".
# Usage: antares_build_digest <dir> [name|path]   (label defaults to basename)
#
# One awk pass, deliberately. The per-file shape this replaces spawned
# basename+grep+sed for EVERY memory — at a few hundred memories that is
# thousands of processes, and it grows with the base. SessionEnd hooks get a
# much smaller time budget than other events (Claude Code defaults them to
# 1.5 s unless the hook declares a `timeout`), so a digest that drifts into
# seconds gets the whole launcher cancelled before it can dispatch its lobo.
antares_build_digest() {
    local dir="$1" mode="${2:-name}" files=()
    shopt -s nullglob
    files=( "$dir"/*.md )
    shopt -u nullglob
    (( ${#files[@]} )) || return 0      # no files: never let awk fall back to stdin
    awk -v mode="$mode" '
        FNR == 1 {
            found = 0
            n = split(FILENAME, p, "/"); base = p[n]
            skip = (base == "MEMORY.md")
            label = (mode == "path") ? FILENAME : base
        }
        skip { nextfile }
        /^description:/ && !found {
            found = 1
            line = $0
            sub(/^description:[[:space:]]*/, "", line)
            sub(/^"/, "", line); sub(/"$/, "", line)
            print "- " label ": " line
            nextfile
        }
        ENDFILE { if (!found && !skip) print "- " label ": (no description)" }
    ' "${files[@]}"
}

# Stable log helper. Usage: antares_log <file> <msg...>
antares_log() {
    local log_file="$ANTARES_STATE/logs/$1"
    shift
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >>"$log_file" 2>/dev/null || true
}
