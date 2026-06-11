#!/usr/bin/env bash
# uninstall.sh — reverses install.sh: unwires hooks, removes deployed files,
# the daemon, the venv, and runtime state.
# DOES NOT touch ~/.claude/projects/<slug>/memory/ (your memory files, all slugs).
# Those live in Claude Code's data dir and are yours.

set -uo pipefail

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
die() { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required to unwire hooks safely — install it first"

confirm=${1:-}
if [[ "$confirm" != "--yes" ]]; then
    cat <<EOF
${BOLD}This will remove:${RESET}
  - This repo's memory hook entries from $SETTINGS_JSON (your other hooks preserved)
  - Deployed scripts (this repo's filenames only) from $CLAUDE_SCRIPTS_DIR
  - The 4 lobos from $CLAUDE_AGENTS_SDK_DIR
  - memory-router / memory-recall from $CLAUDE_AGENTS_DIR
  - Daemon: ~/.config/systemd/user/antares-memory-daemon.service
  - Venv:   $ANTARES_VENV
  - SDK:    $ANTARES_SDK_DIR
  - Logs/state: $ANTARES_STATE  ${YELLOW}(includes the gardener's memory-base tar backups)${RESET}

${BOLD}This will NOT touch:${RESET}
  - ~/.claude/projects/<slug>/memory/  (your memory files — all slugs, preserved)

Re-run with --yes to confirm:
  bash "$0" --yes
EOF
    exit 1
fi

echo "Unwiring hooks from settings.json..."
if [[ -f "$SETTINGS_JSON" ]]; then
    cp -a "$SETTINGS_JSON" "$SETTINGS_JSON.bak.$(date +%s)"
    ls -1t "$SETTINGS_JSON".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    # Strip ONLY hooks whose command is `bash <deploy-dir>/<one of THIS repo's
    # script names>` — a user's own hook pointing at their own file in the same
    # dir (even a memory-*.sh of theirs) is not ours and survives.
    if ! SETTINGS_JSON="$SETTINGS_JSON" CLAUDE_SCRIPTS_DIR="$CLAUDE_SCRIPTS_DIR" \
         REPO_SCRIPTS="$(ls "$SCRIPT_DIR"/scripts/*.sh | xargs -n1 basename)" python3 - <<'PY'
import json, os, sys
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_JSON"])
S = os.environ["CLAUDE_SCRIPTS_DIR"]
ours = {f"bash {S}/{name}" for name in os.environ["REPO_SCRIPTS"].split()}

raw = settings_path.read_text()
try:
    settings = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError as e:
    sys.exit(f"{settings_path} is not valid JSON ({e}) — fix it first; nothing was removed")
hooks = settings.get("hooks", {})

for event in list(hooks):
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", []) if h.get("command") not in ours]
    hooks[event] = [g for g in hooks[event] if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]

out = json.dumps(settings, indent=2) + "\n"
json.loads(out)
settings_path.write_text(out)
print("    memory hooks removed (other hooks untouched)")
PY
    then
        die "could not unwire hooks from $SETTINGS_JSON — fix the file and re-run; NO files were removed"
    fi
fi
printf '%s✓%s hooks unwired\n' "$GREEN" "$RESET"

echo "Stopping daemon..."
systemctl --user disable --now antares-memory-daemon.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/antares-memory-daemon.service"
systemctl --user daemon-reload 2>/dev/null || true
printf '%s✓%s daemon removed\n' "$GREEN" "$RESET"

echo "Removing deployed files..."
# Prefer the deploy manifest (knows exactly what install.sh wrote, including
# files from versions whose names this clone no longer carries); fall back to
# this clone's filenames.
if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done < "$MANIFEST"
else
    for f in "$SCRIPT_DIR"/scripts/*; do
        [[ -f "$f" ]] && rm -f "$CLAUDE_SCRIPTS_DIR/$(basename "$f")"
    done
    for f in "$SCRIPT_DIR"/scripts/lib/*; do
        [[ -f "$f" ]] && rm -f "$CLAUDE_SCRIPTS_DIR/lib/$(basename "$f")"
    done
    for f in "$SCRIPT_DIR"/agents-sdk/*.mjs; do
        rm -f "$CLAUDE_AGENTS_SDK_DIR/$(basename "$f")"
    done
    rm -f "$CLAUDE_AGENTS_SDK_DIR/package.json" "$CLAUDE_AGENTS_SDK_DIR/package-lock.json"
    rm -f "$CLAUDE_AGENTS_DIR/memory-router.md" "$CLAUDE_AGENTS_DIR/memory-recall.md"
fi
[[ -L "$CLAUDE_AGENTS_SDK_DIR/node_modules" ]] && rm -f "$CLAUDE_AGENTS_SDK_DIR/node_modules"
if [[ -d "$CLAUDE_AGENTS_SDK_DIR/node_modules" ]]; then
    printf '%s!%s a real node_modules dir was found in %s — left in place (not ours to judge)\n' "$YELLOW" "$RESET" "$CLAUDE_AGENTS_SDK_DIR"
fi
rmdir "$CLAUDE_SCRIPTS_DIR/lib" "$CLAUDE_SCRIPTS_DIR" "$CLAUDE_AGENTS_SDK_DIR" 2>/dev/null || true
printf '%s✓%s deployed files removed (anything else in those dirs was left alone)\n' "$GREEN" "$RESET"

echo "Removing venv, SDK and state..."
rm -rf "$ANTARES_VENV" "$ANTARES_SDK_DIR" "$ANTARES_STATE"
rmdir "$(dirname "$ANTARES_SDK_DIR")" 2>/dev/null || true
printf '%s✓%s venv + SDK + state removed\n' "$GREEN" "$RESET"

echo
HOME_MEMORY_DIR="$(antares_home_memory_dir)"
printf '%sYour memory files remain under:%s %s\n' "$YELLOW" "$RESET" "$HOME/.claude/projects/<slug>/memory/"
printf '%sHOME slug:%s %s\n' "$YELLOW" "$RESET" "$HOME_MEMORY_DIR"
printf '%sDelete manually if you also want them gone (use with care — every cwd you'\''ve touched has a slug).%s\n' "$YELLOW" "$RESET"
echo
echo "Restart your open Claude Code sessions so they drop the (now unwired) hooks."
