#!/usr/bin/env bash
# migrate.sh — helper for moving existing memories into the slug-based layout.
#
# antares-memory uses Claude Code's native ~/.claude/projects/<slug>/memory/
# convention. If you came from an older path-based layout, this script helps
# consolidate stragglers.
#
# Safe by default: refuses to overwrite. Prints a plan; requires --apply to act.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

APPLY=false
SRC=""
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --src=*) SRC="${arg#--src=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--src=<dir>] [--apply]

Consolidates memories into the HOME slug dir:
    $(antares_home_memory_dir)

Common sources you might want to migrate from:
  - A legacy ~/.claude/memory/ from the legacy pre-slug layout
  - Memories scattered across non-HOME slug dirs that you want global

By default, scans ~/.claude/memory (if it exists) and prints a plan. Add
--apply to actually move the files. Use --src to point at a specific source
(e.g. --src=~/.claude/projects/-home-old-slug/memory).
EOF
            exit 0
            ;;
    esac
done

DST="$(antares_home_memory_dir)"

# Default source: the v0.1.x location.
if [[ -z "$SRC" ]]; then
    LEGACY="$HOME/.claude/memory"
    if [[ -d "$LEGACY" ]]; then
        SRC="$LEGACY"
    else
        cat <<EOF
${BOLD}Nothing obvious to migrate.${RESET}

Your HOME slug dir already exists at:
  $DST

If you have memories elsewhere you want to consolidate here, pass:
  ${GREEN}--src=<path>${RESET}

Common cases:
  --src=~/.claude/memory                                  (legacy v0.1.x)
  --src=~/.claude/projects/<some-old-slug>/memory         (specific other slug)

Run with --help for usage.
EOF
        exit 0
    fi
fi

if [[ ! -d "$SRC" ]]; then
    echo "Source not a directory: $SRC" >&2
    exit 1
fi

if [[ "$(realpath "$SRC")" == "$(realpath "$DST")" ]]; then
    echo "Source and destination are the same. Nothing to do."
    exit 0
fi

mkdir -p "$DST/journal"

printf '%sMigration plan%s\n' "$BOLD" "$RESET"
printf '  Source: %s\n' "$SRC"
printf '  Target: %s\n\n' "$DST"

moves=()
conflicts=()

while IFS= read -r f; do
    rel="${f#$SRC/}"
    target="$DST/$rel"
    if [[ -e "$target" ]]; then
        conflicts+=("$rel")
    else
        moves+=("$rel")
    fi
done < <(find "$SRC" -type f \( -name '*.md' -o -name '.memory-index.db' \) 2>/dev/null)

if [[ ${#moves[@]} -gt 0 ]]; then
    printf '%sWill move %d file(s):%s\n' "$GREEN" "${#moves[@]}" "$RESET"
    for m in "${moves[@]}"; do printf '  + %s\n' "$m"; done
    echo
fi
if [[ ${#conflicts[@]} -gt 0 ]]; then
    printf '%sWill skip %d file(s) (already exist in target):%s\n' "$YELLOW" "${#conflicts[@]}" "$RESET"
    for c in "${conflicts[@]}"; do printf '  ~ %s\n' "$c"; done
    echo
fi

if ! $APPLY; then
    printf 'Dry-run only. Re-run with %s--apply%s to perform the migration.\n' "$BOLD" "$RESET"
    exit 0
fi

if [[ ${#moves[@]} -eq 0 ]]; then
    echo "Nothing to do."
    exit 0
fi

for rel in "${moves[@]}"; do
    src_f="$SRC/$rel"
    tgt_f="$DST/$rel"
    mkdir -p "$(dirname "$tgt_f")"
    mv -n "$src_f" "$tgt_f"
done
printf '\n%sMoved %d file(s).%s\n' "$GREEN" "${#moves[@]}" "$RESET"

if antares_venv_ready; then
    echo "Reindexing HOME slug..."
    "$ANTARES_VENV_PY" "$SCRIPT_DIR/scripts/memory-index.py" --scope home || true
    echo "Done. Daemon will see the new files on the next query."
else
    echo "Venv not ready — run install.sh first."
fi
