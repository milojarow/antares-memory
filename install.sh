#!/usr/bin/env bash
# install.sh — one-time setup for antares-memory-skill.
#
# Storage model: Claude Code's native slug convention. Memories live at
# ~/.claude/projects/<slugify(cwd)>/memory/ — one slug per cwd. The HOME slug
# (cwd == $HOME) is the "global" by convention. Each slug's MEMORY.md is
# auto-loaded by Claude Code when its cwd matches — no @-import required.
#
# Idempotent. Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

say()  { printf '%s%s%s\n'  "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

say "antares-memory-skill installer"
echo

# ─── 1. Dependency check ──────────────────────────────────────────────────────
say "1/7  Checking dependencies"
for cmd in python3 jq socat sqlite3 systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Missing required command: $cmd"
    fi
done
py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
py_major=$(echo "$py_ver" | cut -d. -f1)
py_minor=$(echo "$py_ver" | cut -d. -f2)
if (( py_major < 3 )) || { (( py_major == 3 )) && (( py_minor < 10 )); }; then
    die "python3 >= 3.10 required (have $py_ver)"
fi
if ! systemctl --user status >/dev/null 2>&1 \
   && ! systemctl --user --version >/dev/null 2>&1; then
    warn "systemctl --user is not available — daemon will need manual launch"
fi
ok "deps present (python $py_ver, jq, socat, sqlite3, systemctl)"

# ─── 2. Create directories ────────────────────────────────────────────────────
say "2/7  Creating directories"
HOME_MEMORY_DIR="$(antares_home_memory_dir)"
mkdir -p "$HOME_MEMORY_DIR/journal"
mkdir -p "$ANTARES_STATE/logs"
mkdir -p "$(dirname "$ANTARES_VENV")"
ok "$HOME_MEMORY_DIR (HOME slug memory store)"
ok "$ANTARES_STATE (logs)"

# ─── 3. Seed MEMORY.md ────────────────────────────────────────────────────────
say "3/7  Seeding MEMORY.md in HOME slug (only if missing)"
MEMORY_INDEX="$HOME_MEMORY_DIR/MEMORY.md"
if [[ ! -f "$MEMORY_INDEX" ]]; then
    cat > "$MEMORY_INDEX" <<'EOF'
# Memory — Always-on directives

This file is auto-loaded by Claude Code whenever your cwd matches its slug
(this file lives in the HOME slug — loaded when cwd == $HOME).

Domain-specific memories auto-load via the `UserPromptSubmit` hook by
semantic similarity. List below the few entries you want always-loaded
regardless of the current prompt.

Format: one line per entry.

- (no entries yet — add your own as you accumulate memories)
EOF
    ok "wrote initial $MEMORY_INDEX"
else
    ok "$MEMORY_INDEX already exists — left as is"
fi

# ─── 4. Python venv + deps ────────────────────────────────────────────────────
say "4/7  Setting up runtime deps — Python venv + Node SDK (downloads ~400MB on first run)"
if [[ ! -x "$ANTARES_VENV_PY" ]]; then
    python3 -m venv "$ANTARES_VENV"
    ok "created venv at $ANTARES_VENV"
else
    ok "venv exists at $ANTARES_VENV"
fi

"$ANTARES_VENV/bin/pip" install --quiet --upgrade pip

if ! "$ANTARES_VENV_PY" -c "import sentence_transformers" 2>/dev/null; then
    echo "    Installing sentence-transformers (+ torch CPU)..."
    "$ANTARES_VENV/bin/pip" install --quiet \
        --index-url https://download.pytorch.org/whl/cpu \
        --extra-index-url https://pypi.org/simple \
        sentence-transformers numpy
    ok "installed sentence-transformers"
else
    ok "sentence-transformers already installed"
fi

# Pre-download the embedding model so the first daemon start isn't slow.
echo "    Pre-downloading model $ANTARES_MODEL..."
"$ANTARES_VENV_PY" - <<PY
from sentence_transformers import SentenceTransformer
SentenceTransformer("$ANTARES_MODEL")
PY
ok "model $ANTARES_MODEL cached"

# Node SDK for the lobos — installed ONCE in a STABLE dir (like the Python venv
# above), NOT in the per-version plugin cache. This survives plugin updates; the
# launchers symlink the cache's agents-sdk/node_modules to it on demand, so the
# lobos never go mute after an update. (ESM ignores NODE_PATH → a symlink is the
# native-feeling fix.)
if command -v npm >/dev/null 2>&1; then
    echo "    Installing the Agent SDK (stable home, survives plugin updates)..."
    mkdir -p "$ANTARES_SDK_DIR"
    cp "$SCRIPT_DIR/agents-sdk/package.json" "$SCRIPT_DIR/agents-sdk/package-lock.json" "$ANTARES_SDK_DIR/"
    if ( cd "$ANTARES_SDK_DIR" && npm ci --no-audit --no-fund ); then
        ok "SDK installed at $ANTARES_SDK_DIR (@anthropic-ai/claude-agent-sdk)"
        antares_link_sdk "$SCRIPT_DIR/agents-sdk" && ok "linked plugin cache → stable SDK"
    else
        warn "npm ci failed — SDK lobos won't run until it succeeds (see reference/lobos-agents-sdk.md)"
    fi
else
    warn "npm not found — SDK lobos skipped. Install Node, then re-run /antares-memory:install"
fi

# ─── 5. systemd user unit ─────────────────────────────────────────────────────
say "5/7  Installing systemd user unit"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/antares-memory-daemon.service"
mkdir -p "$UNIT_DIR"

DAEMON_SCRIPT="$SCRIPT_DIR/scripts/memory-search-daemon.py"

sed \
    -e "s|@ANTARES_VENV_PY@|$ANTARES_VENV_PY|g" \
    -e "s|@ANTARES_DAEMON_SCRIPT@|$DAEMON_SCRIPT|g" \
    -e "s|@ANTARES_MODEL@|$ANTARES_MODEL|g" \
    -e "s|@ANTARES_STATE@|$ANTARES_STATE|g" \
    "$SCRIPT_DIR/systemd/antares-memory-daemon.service.tmpl" \
    > "$UNIT_FILE"
ok "wrote $UNIT_FILE"

systemctl --user daemon-reload
systemctl --user enable antares-memory-daemon.service
# restart (not enable --now): on a re-install over an already-running daemon,
# --now is a no-op and the live process keeps stale code; restart guarantees the
# running process matches the unit file just written.
systemctl --user restart antares-memory-daemon.service
sleep 1
if systemctl --user is-active --quiet antares-memory-daemon.service; then
    ok "daemon running"
else
    warn "daemon not active — run 'systemctl --user status antares-memory-daemon' for details"
fi

# ─── 6. First-time index pass ─────────────────────────────────────────────────
say "6/7  Running first index pass"
"$ANTARES_VENV_PY" "$SCRIPT_DIR/scripts/memory-index.py" --scope home || true
ok "index ready"

# ─── 7. Final notes ───────────────────────────────────────────────────────────
say "7/7  Done!"
echo
cat <<EOF
${BOLD}Next steps:${RESET}

  1. Open a new Claude Code session from \$HOME. Claude Code automatically
     loads:
       ${GREEN}$MEMORY_INDEX${RESET}
     as the session's MEMORY.md — no \`@\`-import in your CLAUDE.md needed.

  2. When you cd into a project, Claude Code loads:
       ${GREEN}~/.claude/projects/<that-slug>/memory/MEMORY.md${RESET}
     (if it exists). New cwds get their own slug dir on first session-start.

  3. Diagnose anytime: ${GREEN}/antares-memory:status${RESET}

  4. Already have memories under a non-standard path that you want to
     consolidate into the HOME slug? Run: ${GREEN}/antares-memory:migrate${RESET}

EOF
