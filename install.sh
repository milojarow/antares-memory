#!/usr/bin/env bash
# install.sh — installs antares-memory as SYSTEM functionality for Claude Code.
#
# This is NOT a Claude Code plugin. Memory is infrastructure that runs around
# the model (hooks, headless lobos, a search daemon) — it gets wired into
# stable system locations, and no skill ever loads into context for it:
#   ~/.claude/scripts/       the hook scripts + prompts + lib/
#   ~/.claude/agents-sdk/    the 4 headless lobos (Agent SDK)
#   ~/.claude/agents/        memory-router + memory-recall subagents
#   ~/.claude/settings.json  the 5 hook events (merged, non-destructive)
#   ~/.config/systemd/user/  the search-daemon unit (stable path)
#
# Storage model: Claude Code's native slug convention. Memories live at
# ~/.claude/projects/<slugify(cwd)>/memory/ — one slug per cwd. The HOME slug
# (cwd == $HOME) is the "global" by convention. Each slug's MEMORY.md is
# auto-loaded by Claude Code when its cwd matches — no @-import required.
#
# Idempotent: re-running it IS the update path (git pull && ./install.sh).
# A deploy manifest (state dir) lets re-runs remove files/hooks that a newer
# version of the repo no longer ships.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

CLAUDE_SCRIPTS_DIR="$HOME/.claude/scripts"
CLAUDE_AGENTS_SDK_DIR="$HOME/.claude/agents-sdk"
CLAUDE_AGENTS_DIR="$HOME/.claude/agents"
SETTINGS_JSON="$HOME/.claude/settings.json"
MANIFEST="$ANTARES_STATE/deploy-manifest.txt"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

say()  { printf '%s%s%s\n'  "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

say "antares-memory installer (system mode)"
echo

if [[ "$SCRIPT_DIR" == "$CLAUDE_SCRIPTS_DIR" || "$SCRIPT_DIR" == "$HOME/.claude"* ]]; then
    die "Run the installer from the cloned repo, not from a deploy location."
fi

# ─── 1/8 Dependency check ─────────────────────────────────────────────────────
say "1/8  Checking dependencies"
missing=()
for cmd in python3 jq socat sqlite3 systemctl node npm git; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]} — install them with your package manager (e.g. sudo pacman -S --needed ${missing[*]} / sudo apt install ${missing[*]}), then re-run ./install.sh"
fi
py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
py_major=$(echo "$py_ver" | cut -d. -f1)
py_minor=$(echo "$py_ver" | cut -d. -f2)
if (( py_major < 3 )) || { (( py_major == 3 )) && (( py_minor < 10 )); }; then
    die "python3 >= 3.10 required (have $py_ver)"
fi
if ! sqlite3 ":memory:" "CREATE VIRTUAL TABLE t USING fts5(x)" >/dev/null 2>&1; then
    die "sqlite3 lacks FTS5 support — the keyword half of hybrid search needs it. Install a full sqlite3 build, then re-run ./install.sh"
fi
# Real user-bus probe: `systemctl --user --version` never touches the bus, so it
# proves nothing. show-environment does.
HAVE_USER_SYSTEMD=0
if systemctl --user show-environment >/dev/null 2>&1; then
    HAVE_USER_SYSTEMD=1
else
    warn "no reachable systemd user instance — the daemon will be installed but you must launch it manually (shown at step 7)"
fi
ok "deps present (python $py_ver, node $(node --version), jq, socat, sqlite3+FTS5, git)"

# ─── 2/8 Directories + seed MEMORY.md ─────────────────────────────────────────
say "2/8  Creating directories"
HOME_MEMORY_DIR="$(antares_home_memory_dir)"
mkdir -p "$HOME_MEMORY_DIR/journal"
mkdir -p "$ANTARES_STATE/logs"
mkdir -p "$(dirname "$ANTARES_VENV")"
ok "$HOME_MEMORY_DIR (HOME slug memory store)"
ok "$ANTARES_STATE (logs)"

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

# ─── 3/8 Python venv + embedding model ────────────────────────────────────────
say "3/8  Python venv + embedding model (downloads ~400MB on first run)"
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

echo "    Pre-downloading model $ANTARES_MODEL (cached under ~/.cache/huggingface)..."
"$ANTARES_VENV_PY" - <<PY
from sentence_transformers import SentenceTransformer
SentenceTransformer("$ANTARES_MODEL")
PY
ok "model $ANTARES_MODEL cached"

# ─── 4/8 Agent SDK (stable home) ──────────────────────────────────────────────
say "4/8  Installing the Agent SDK (stable home at $ANTARES_SDK_DIR)"
mkdir -p "$ANTARES_SDK_DIR"
cp "$SCRIPT_DIR/agents-sdk/package.json" "$SCRIPT_DIR/agents-sdk/package-lock.json" "$ANTARES_SDK_DIR/"
if ( cd "$ANTARES_SDK_DIR" && npm ci --no-audit --no-fund ); then
    ok "SDK installed (@anthropic-ai/claude-agent-sdk)"
else
    die "npm ci failed — the lobos can't run without the SDK. Fix npm/network and re-run ./install.sh"
fi

# ─── 5/8 Deploy system files ──────────────────────────────────────────────────
say "5/8  Deploying to system locations"
mkdir -p "$CLAUDE_SCRIPTS_DIR/lib" "$CLAUDE_AGENTS_SDK_DIR" "$CLAUDE_AGENTS_DIR"

# Build the new deploy manifest (absolute target paths) from the repo content.
new_manifest=""
deploy() {  # deploy <src-file> <dst-dir>
    cp "$1" "$2/"
    new_manifest+="$2/$(basename "$1")"$'\n'
}
for f in "$SCRIPT_DIR"/scripts/*;       do [[ -f "$f" ]] && deploy "$f" "$CLAUDE_SCRIPTS_DIR"; done
for f in "$SCRIPT_DIR"/scripts/lib/*;   do [[ -f "$f" ]] && deploy "$f" "$CLAUDE_SCRIPTS_DIR/lib"; done
for f in "$SCRIPT_DIR"/agents-sdk/*.mjs "$SCRIPT_DIR"/agents-sdk/package.json "$SCRIPT_DIR"/agents-sdk/package-lock.json; do
    deploy "$f" "$CLAUDE_AGENTS_SDK_DIR"
done
for f in "$SCRIPT_DIR"/agents/memory-router.md "$SCRIPT_DIR"/agents/memory-recall.md; do
    deploy "$f" "$CLAUDE_AGENTS_DIR"
done
ok "scripts → $CLAUDE_SCRIPTS_DIR · lobos → $CLAUDE_AGENTS_SDK_DIR · agents → $CLAUDE_AGENTS_DIR"

# Reconcile: remove files a previous version deployed that this version no
# longer ships (rename/removal upstream must not leave live orphans).
if [[ -f "$MANIFEST" ]]; then
    removed=0
    while IFS= read -r old; do
        [[ -z "$old" ]] && continue
        if ! grep -qxF "$old" <<<"$new_manifest" && [[ -f "$old" && ! -d "$old" ]]; then
            rm -f "$old" && removed=$((removed+1))
        fi
    done < "$MANIFEST"
    (( removed > 0 )) && ok "removed $removed orphaned file(s) from a previous version"
fi
printf '%s' "$new_manifest" > "$MANIFEST"

# The lobos resolve their SDK through a symlink to the stable install — ESM
# ignores NODE_PATH, a symlink is the native-feeling fix. A REAL node_modules
# dir here (e.g. someone ran `npm install` in the deploy dir) would swallow the
# symlink (`ln -sfn` nests INSIDE a real dir) and pin stale deps forever:
# replace it — it only ever holds deps reproducible from the stable SDK.
if [[ -d "$CLAUDE_AGENTS_SDK_DIR/node_modules" && ! -L "$CLAUDE_AGENTS_SDK_DIR/node_modules" ]]; then
    warn "replacing a real node_modules dir in $CLAUDE_AGENTS_SDK_DIR with the stable-SDK symlink"
    rm -rf "$CLAUDE_AGENTS_SDK_DIR/node_modules"
fi
ln -sfn "$ANTARES_SDK_DIR/node_modules" "$CLAUDE_AGENTS_SDK_DIR/node_modules"
ok "node_modules → stable SDK"

# ─── 6/8 Wire hooks into settings.json ────────────────────────────────────────
say "6/8  Wiring hooks into $SETTINGS_JSON (non-destructive merge)"
if [[ -f "$SETTINGS_JSON" ]]; then
    cp -a "$SETTINGS_JSON" "$SETTINGS_JSON.bak.$(date +%s)"
    # Keep only the 5 newest backups — install is the routine update path.
    ls -1t "$SETTINGS_JSON".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
fi
if ! SETTINGS_JSON="$SETTINGS_JSON" CLAUDE_SCRIPTS_DIR="$CLAUDE_SCRIPTS_DIR" \
     REPO_SCRIPTS="$(ls "$SCRIPT_DIR"/scripts/*.sh | xargs -n1 basename)" python3 - <<'PY'
import json, os, sys
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_JSON"])
S = os.environ["CLAUDE_SCRIPTS_DIR"]
repo_scripts = set(os.environ["REPO_SCRIPTS"].split())

if settings_path.exists():
    raw = settings_path.read_text()
    try:
        settings = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        sys.exit(f"{settings_path} is not valid JSON ({e}) — fix or remove it, then re-run ./install.sh")
else:
    settings = {}
hooks = settings.setdefault("hooks", {})

def entry(script, timeout):
    return {"type": "command", "command": f"bash {S}/{script}", "timeout": timeout}

WANTED = {
    "SessionStart":     ("startup|resume|clear|compact",
                         [entry("memory-journal-init.sh", 10), entry("memory-reindex.sh", 60)]),
    "UserPromptSubmit": (".*", [entry("memory-search-hook.sh", 5)]),
    "PreCompact":       ("manual|auto", [entry("memory-chronicle-launch.sh", 30)]),
    "SessionEnd":       (None, [entry("memory-chronicle-launch.sh", 30),
                                entry("memory-gardener-launch.sh", 10),
                                entry("memory-curator-launch.sh", 10)]),
    "PostToolUse":      ("Write|Edit|MultiEdit", [entry("memory-reindex-if-touched.sh", 5)]),
}

wanted_cmds = {h["command"] for _, hs in WANTED.values() for h in hs}
# Commands that are OURS (this repo's script names under the deploy dir) but no
# longer wanted — stale entries from a previous version. Never touches a user's
# own hooks, even ones pointing at their own files in the same dir.
ours = {f"bash {S}/{name}" for name in repo_scripts}

for event in list(hooks):
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", [])
                      if not (h.get("command") in ours and h.get("command") not in wanted_cmds)]
    hooks[event] = [g for g in hooks[event] if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]

for event, (matcher, wanted_hooks) in WANTED.items():
    groups = hooks.setdefault(event, [])
    group = next((g for g in groups if g.get("matcher") == matcher
                  or (matcher is None and "matcher" not in g)), None)
    if group is None:
        group = {"hooks": []}
        if matcher is not None:
            group["matcher"] = matcher
        groups.append(group)
    have = {h.get("command") for h in group["hooks"]}
    for h in wanted_hooks:
        if h["command"] not in have:
            group["hooks"].append(h)

out = json.dumps(settings, indent=2) + "\n"
json.loads(out)  # self-validation before touching the file
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings_path.write_text(out)
print("    merged 8 hook entries across 5 events (existing hooks preserved)")
PY
then
    die "could not wire hooks into $SETTINGS_JSON — see the message above; nothing else was changed"
fi
ok "hooks wired (timestamped backup kept next to settings.json)"

# ─── 7/8 systemd user unit (stable path) ──────────────────────────────────────
say "7/8  Installing the search-daemon unit"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/antares-memory-daemon.service"
mkdir -p "$UNIT_DIR"

# ExecStart points at the DEPLOYED copy — a stable path that survives repo
# moves and updates (re-running this installer refreshes the deployed copy
# and restarts the daemon).
DAEMON_SCRIPT="$CLAUDE_SCRIPTS_DIR/memory-search-daemon.py"

sed \
    -e "s|@ANTARES_VENV_PY@|$ANTARES_VENV_PY|g" \
    -e "s|@ANTARES_DAEMON_SCRIPT@|$DAEMON_SCRIPT|g" \
    -e "s|@ANTARES_MODEL@|$ANTARES_MODEL|g" \
    -e "s|@ANTARES_STATE@|$ANTARES_STATE|g" \
    "$SCRIPT_DIR/systemd/antares-memory-daemon.service.tmpl" \
    > "$UNIT_FILE"
ok "wrote $UNIT_FILE"

if (( HAVE_USER_SYSTEMD )); then
    systemctl --user daemon-reload
    systemctl --user enable antares-memory-daemon.service
    # restart (not enable --now): on a re-install over an already-running daemon,
    # --now is a no-op and the live process keeps stale code; restart guarantees
    # the running process matches the files just deployed.
    systemctl --user restart antares-memory-daemon.service

    SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/memory-search.sock"
    deadline=$(( $(date +%s) + 60 ))
    until printf '{"op":"ping"}\n' | timeout 2 socat -t 2 - "UNIX-CONNECT:$SOCKET" 2>/dev/null | grep -q '"pong"' \
          || (( $(date +%s) > deadline )); do
        sleep 2
    done
    if printf '{"op":"ping"}\n' | timeout 2 socat -t 2 - "UNIX-CONNECT:$SOCKET" 2>/dev/null | grep -q '"pong"'; then
        ok "daemon running and responsive at $SOCKET"
    else
        warn "daemon not responding yet — check: systemctl --user status antares-memory-daemon"
    fi
else
    warn "no systemd user instance — launch the daemon manually:"
    echo "      $ANTARES_VENV_PY $DAEMON_SCRIPT &"
fi

# ─── 8/8 First index pass + next steps ────────────────────────────────────────
say "8/8  Running first index pass"
if "$ANTARES_VENV_PY" "$CLAUDE_SCRIPTS_DIR/memory-index.py" --scope home; then
    ok "index ready"
else
    warn "first index pass failed — recall will be empty until it succeeds; check $ANTARES_STATE/logs/ and re-run: $ANTARES_VENV_PY $CLAUDE_SCRIPTS_DIR/memory-index.py --scope home"
fi

echo
cat <<EOF
${BOLD}Done. Next steps:${RESET}

  1. ${BOLD}Restart your Claude Code sessions${RESET} — hooks are read at session start;
     sessions already open don't have them yet.

  2. Open a session from \$HOME. Claude Code auto-loads:
       ${GREEN}$MEMORY_INDEX${RESET}
     and from now on every prompt gets semantically-relevant memories injected,
     and every session close runs the capture lobos.

  3. Diagnose anytime: ${GREEN}$SCRIPT_DIR/status.sh${RESET}

  4. Update later: ${GREEN}git -C $SCRIPT_DIR pull && $SCRIPT_DIR/install.sh${RESET}
     (idempotent — re-deploys files, re-merges hooks, restarts the daemon)

EOF
