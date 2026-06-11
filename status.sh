#!/usr/bin/env bash
# status.sh — diagnostic snapshot of the antares-memory installation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
hdr()  { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

HOME_MEMORY_DIR="$(antares_home_memory_dir)"
CURRENT_MEMORY_DIR="$(antares_memory_dir_for "$PWD")"

hdr "Paths"
ok "HOME slug    = $HOME_MEMORY_DIR"
ok "CURRENT slug = $CURRENT_MEMORY_DIR"
ok "ANTARES_VENV  = $ANTARES_VENV"
ok "ANTARES_STATE = $ANTARES_STATE"
ok "ANTARES_MODEL = $ANTARES_MODEL"

hdr "Venv"
if antares_venv_ready; then
    py_ver=$("$ANTARES_VENV_PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    st_ver=$("$ANTARES_VENV_PY" -c 'import sentence_transformers; print(sentence_transformers.__version__)' 2>/dev/null || echo "?")
    ok "python $py_ver, sentence-transformers $st_ver"
else
    bad "venv not ready — run ./install.sh"
fi

hdr "Deployed system files"
CLAUDE_SCRIPTS_DIR="$HOME/.claude/scripts"
missing=0
for f in "$SCRIPT_DIR"/scripts/* "$SCRIPT_DIR"/scripts/lib/*; do
    [[ -f "$f" ]] || continue
    rel="$(basename "$f")"
    [[ "$f" == */lib/* ]] && rel="lib/$rel"
    [[ -f "$CLAUDE_SCRIPTS_DIR/$rel" ]] || { bad "missing: $CLAUDE_SCRIPTS_DIR/$rel"; missing=1; }
done
(( missing == 0 )) && ok "all scripts deployed at $CLAUDE_SCRIPTS_DIR (incl. lib/)"
missing=0
for f in "$SCRIPT_DIR"/agents-sdk/*.mjs; do
    [[ -f "$HOME/.claude/agents-sdk/$(basename "$f")" ]] || { bad "missing lobo: ~/.claude/agents-sdk/$(basename "$f")"; missing=1; }
done
(( missing == 0 )) && ok "all 4 lobos deployed at ~/.claude/agents-sdk/"
sdk_link="$HOME/.claude/agents-sdk/node_modules"
if [[ -e "$sdk_link/@anthropic-ai/claude-agent-sdk/package.json" ]]; then
    ok "lobos SDK resolves at ~/.claude/agents-sdk/"
else
    bad "lobos SDK not resolving — run ./install.sh"
fi
for a in memory-router memory-recall; do
    [[ -f "$HOME/.claude/agents/$a.md" ]] && ok "agent $a deployed" || bad "agent $a missing"
done

hdr "Hooks in ~/.claude/settings.json"
if [[ -f "$HOME/.claude/settings.json" ]]; then
    # Exact-command check against the same 8 entries install.sh wires — a fuzzy
    # substring count would let a user's own memory-* hooks mask missing ones.
    expected=(
        "bash $CLAUDE_SCRIPTS_DIR/memory-journal-init.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-reindex.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-search-hook.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-chronicle-launch.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-gardener-launch.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-curator-launch.sh"
        "bash $CLAUDE_SCRIPTS_DIR/memory-reindex-if-touched.sh"
    )
    wired=0
    hook_missing=0
    for cmd in "${expected[@]}"; do
        if jq -e --arg c "$cmd" '[.hooks // {} | to_entries[] | .value[].hooks[]? | select((.command? // "") == $c)] | length > 0' \
              "$HOME/.claude/settings.json" >/dev/null 2>&1; then
            wired=$((wired+1))
        else
            bad "hook not wired: $cmd"
            hook_missing=1
        fi
    done
    # chronicle is wired twice (PreCompact + SessionEnd) — verify both.
    chr=$(jq -r --arg c "bash $CLAUDE_SCRIPTS_DIR/memory-chronicle-launch.sh" \
        '[.hooks // {} | to_entries[] | .value[].hooks[]? | select((.command? // "") == $c)] | length' \
        "$HOME/.claude/settings.json" 2>/dev/null || echo 0)
    if [[ "${chr:-0}" -lt 2 ]]; then
        bad "chronicle wired ${chr:-0}/2 times (needs PreCompact + SessionEnd)"
        hook_missing=1
    fi
    (( hook_missing == 0 )) && ok "all 8 hook entries wired across 5 events"
else
    bad "no ~/.claude/settings.json — run ./install.sh"
fi

scope_summary() {
    local label="$1"
    local mdir="$2"
    hdr "$label memory dir"
    if [[ ! -d "$mdir" ]]; then
        warn "$mdir does not exist (will be created on first use)"
        return
    fi
    local md_count journal_count db_size chunks
    md_count=$(find "$mdir" -maxdepth 1 -name '*.md' -not -name 'MEMORY.md' 2>/dev/null | wc -l)
    journal_count=$(find "$mdir/journal" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
    ok "$md_count memory file(s), $journal_count journal entries"
    if [[ -f "$mdir/MEMORY.md" ]]; then
        ok "MEMORY.md present (Claude Code auto-loads it when cwd matches this slug)"
    else
        warn "MEMORY.md missing"
    fi
    if [[ -f "$mdir/.memory-index.db" ]]; then
        db_size=$(du -h "$mdir/.memory-index.db" | cut -f1)
        chunks=$(sqlite3 "$mdir/.memory-index.db" "SELECT COUNT(*) FROM memory_chunks" 2>/dev/null || echo "?")
        ok "SQLite index: $db_size, $chunks chunks"
    else
        warn "no SQLite index yet"
    fi
}

scope_summary "HOME" "$HOME_MEMORY_DIR"
if [[ "$CURRENT_MEMORY_DIR" != "$HOME_MEMORY_DIR" ]]; then
    scope_summary "CURRENT" "$CURRENT_MEMORY_DIR"
fi

hdr "Daemon"
SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/memory-search.sock"
if systemctl --user is-active --quiet antares-memory-daemon.service 2>/dev/null; then
    ok "systemd unit active"
elif systemctl --user list-unit-files antares-memory-daemon.service 2>/dev/null | grep -q antares-memory; then
    bad "systemd unit installed but not active"
else
    bad "systemd unit not installed"
fi
if [[ -S "$SOCKET" ]]; then
    pong=$(printf '{"op":"ping"}\n' | timeout 2 socat -t 2 - "UNIX-CONNECT:$SOCKET" 2>/dev/null || echo "")
    if [[ "${pong//[[:space:]]/}" == *'"pong":true'* ]]; then
        ok "socket responsive at $SOCKET"
    else
        bad "socket exists but ping failed"
    fi
else
    bad "no socket at $SOCKET"
fi

hdr "Logs (last 3 lines per file)"
for f in "$ANTARES_STATE/logs"/*.log; do
    [[ -f "$f" ]] || continue
    printf '  %s%s%s\n' "$BOLD" "$(basename "$f")" "$RESET"
    tail -n 3 "$f" 2>/dev/null | sed 's/^/    /'
done

echo
