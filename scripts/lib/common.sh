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

# The GLOBAL memory dir. Defaults to the $HOME slug, which is the canonical
# layout; an override points elsewhere, in this precedence:
#
#   1. $ANTARES_GLOBAL_MEMORY_DIR
#   2. $XDG_CONFIG_HOME/antares-memory/global-memory-dir  (a file holding the path)
#   3. the $HOME slug
#
# The override is not a nicety, it is what lets one install keep a store that
# predates the slug layout without forking these scripts. Its Python twin in
# common.py reads both sources in the same order — the two halves MUST agree on
# where "global" is, and for a while they did not: the shell side had the
# override and the Python side did not, so an installer run would have repointed
# indexing and search at an empty slug dir while the real store sat untouched.
# Every memory still on disk, none of them findable, and no error anywhere.
#
# THE FILE EXISTS BECAUSE THE ENVIRONMENT VARIABLE ALONE DOES NOT REACH THE
# CONSUMERS. This was documented as "set it in the systemd user environment, the
# hooks are children of systemd" — which is false, and measurably so. Only the
# daemon is a child of systemd. Every hook and every lobo is a child of the
# Claude Code process, which is a child of the terminal, the compositor, and the
# login session: a process tree that inherited its environment at login and
# cannot be amended afterwards. On the machine that shipped this, `environment.d`
# was written at 00:38 and the session had started six days earlier — so
# `systemctl --user show-environment` displayed the variable, the daemon had it,
# and all 15 Claude-descendant processes did not. Search (daemon) resolved the
# real store while indexing and the lobos (hooks) resolved the empty slug dir.
# The split survives a terminal restart and only heals on a full re-login, which
# is exactly the kind of "fixed itself" that hides the cause.
#
# A file is read at the moment of use by whoever needs it, so it has no
# inheritance to lose. Keep the variable first: it stays useful for one-off runs
# and for overriding a machine's default in a single command.
#
# If you add a third consumer, teach it this resolution too.
antares_home_memory_dir() {
    if [[ -n "${ANTARES_GLOBAL_MEMORY_DIR:-}" ]]; then
        printf '%s' "$ANTARES_GLOBAL_MEMORY_DIR"
        return
    fi

    local conf="${XDG_CONFIG_HOME:-$HOME/.config}/antares-memory/global-memory-dir"
    if [[ -r "$conf" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == '#'* ]] && continue
            printf '%s' "$line"
            return
        done < "$conf"
    fi

    antares_memory_dir_for "$HOME"
}

# Boolean: does the venv exist and have sentence-transformers?
#
# AUTHORITATIVE BUT EXPENSIVE — it actually imports, and sentence_transformers
# drags in torch: measured at 5.7 SECONDS against 22ms for bare interpreter
# startup. Use it in installers and background workers, NEVER in the foreground
# of a hook. A PostToolUse hook declaring `timeout: 5` was calling this before
# forking its worker, so it was killed on every single fire, having done nothing
# — for weeks, and silently, because a hook killed by its timeout looks exactly
# like a hook that had no work to do. Foreground callers want the cheap check
# below.
antares_venv_ready() {
    [[ -x "$ANTARES_VENV_PY" ]] \
        && "$ANTARES_VENV_PY" -c "import sentence_transformers" 2>/dev/null
}

# Boolean: does the venv LOOK installed? Filesystem only — no interpreter start,
# no import, ~4ms. This is the check to use on a hook's critical path; the worker
# it guards still fails loudly (and now logs) if the install is genuinely broken,
# so the weaker test costs nothing but a slightly later error.
antares_venv_present() {
    [[ -x "$ANTARES_VENV_PY" ]] || return 1
    compgen -G "$ANTARES_VENV/lib/python*/site-packages/sentence_transformers" >/dev/null 2>&1
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
