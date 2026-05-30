# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is the **antares-memory-skill** repository — a turnkey persistent-memory system for Claude Code, packaged as an installable plugin.

**Repository**: https://github.com/milojarow/antares-memory-skill

## Repository Structure

```
antares-memory-skill/
├── .claude-plugin/                # plugin.json + marketplace.json
├── CLAUDE.md                      # This file
├── README.md                      # User-facing pitch + install steps
├── LICENSE                        # MIT
├── evaluations/                   # GREEN validation scenarios
├── hooks/hooks.json               # The 4 hooks (UserPromptSubmit, SessionStart, PreCompact, PostToolUse)
├── scripts/                       # 9 generalized scripts + lib/common.sh + lib/common.py
├── systemd/                       # Daemon service template
├── commands/                      # /antares-memory:install|migrate|status|uninstall
├── install.sh / migrate.sh /
│   status.sh / uninstall.sh       # Implementations
└── skills/
    └── antares-memory/
        ├── SKILL.md               # Entry point — WHEN-to-use only (CSO)
        └── reference/             # architecture, taxonomy, writing, tuning, troubleshooting
```

## The skill

### antares-memory
Documents the memory system: frontmatter taxonomy (`feedback_*` / `reference_*` / `project_*` / `user_*` / `tool_*`), global vs project scope decision rule, dedup discipline, hybrid search tuning (cosine + BM25 weights, threshold), and how to run / troubleshoot the daemon. Activates when the user mentions memory/recall/save, edits files under `~/.claude/memory/`, or runs an `/antares-memory:*` command.

## Architecture

5 layers (see `skills/antares-memory/reference/architecture.md` for detail):

1. **Storage** — flat `.md` files at `~/.claude/projects/<slugify(cwd)>/memory/` — Claude Code's native convention; each cwd has its own slug dir, each with its own `MEMORY.md` auto-loaded when cwd matches
2. **Indexer** — `memory-index.py`: paragraph-aware chunking (120 tokens, overlap 30) + sentence-transformers embeddings + SQLite FTS5, per slug
3. **Search** — `memory-search.py` + `memory-search-daemon.py`: hybrid cosine (70%) + BM25 (30%), threshold 0.35, UNIX socket; queries the HOME and CURRENT slug DBs
4. **Auto-inject** — `memory-search-hook.sh` on UserPromptSubmit; `memory-journal-init.sh` on SessionStart (journal lives in HOME slug)
5. **Auto-capture** — `memory-chronicle-launch.sh` on PreCompact + SessionEnd runs the chronicle pipeline (cronista → journal, destilador → memories) as isolated Agent SDK lobos, writing to HOME or CURRENT per the lesson

## Persistence layout (after install)

```
~/.claude/projects/<slug>/memory/            # USER DATA — Claude Code's native location
├── MEMORY.md                                # Auto-loaded by Claude Code when cwd matches this slug
├── *.md                                     # Memory files (frontmatter + body)
├── journal/YYYY-MM-DD.md                    # Daily journal (only in HOME slug)
└── .memory-index.db                         # SQLite (embeddings + FTS5)

~/.local/share/antares-memory/venv/          # Python venv (sentence-transformers, numpy, torch CPU)
~/.local/state/antares-memory/logs/          # All script logs
~/.config/systemd/user/antares-memory-daemon.service   # Daemon unit
$XDG_RUNTIME_DIR/memory-search.sock          # Daemon socket (ephemeral)
```

`<slug>` = `cwd.replace('/', '-')`. HOME slug = `slugify($HOME)`. Memory files NEVER get overwritten by plugin updates — they live in Claude Code's own data dir, outside the plugin cache.

The plugin cache (`~/.claude/plugins/cache/.../antares-memory-skill/`) holds the scripts. Plugin updates rebuild it. Persistent state lives outside.

## Updating this skill

After any cycle that discovers a new pattern, gotcha, or operator-facing tweak. Keep entries generic — never embed personal names, client identifiers, or private hostnames. The git log is the diary.

When iterating:
1. Edit in `~/skills-dev/drafts/antares-memory-skill/` (this dir, the source)
2. Bump version in **both** `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json`
3. Commit + push
4. Operators get the update on next Claude Code startup (marketplace auto-update)

## Validation discipline (forjador-de-skills pipeline)

- **Privacy scrub** — sweep for personal names, internal hostnames, legacy `~/.claude/projects/<slug>/memory/` paths, and client identifiers before commit. The repo is public; treat it that way.
- **GREEN validation** — subagent with only this skill loaded must answer scenarios in `evaluations/scenarios.md`.
- **Idempotence** — `install.sh` must be safe to re-run; running it twice should not break anything.
