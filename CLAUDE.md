# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is **antares-memory** — a turnkey persistent-memory system for Claude Code, packaged as a **system installer** (NOT a plugin, NOT a skill).

**Repository**: https://github.com/milojarow/antares-memory

It was a Claude Code plugin until 2026-06-10; the plugin packaging was removed deliberately. Infrastructure (hooks, headless lobos, a daemon) needs stable paths and deliberate updates — `${CLAUDE_PLUGIN_ROOT}` versioned cache dirs generated a family of production bugs (stale daemon ExecStart, orphaned SDK node_modules, resumed-session hook skew). Do NOT re-add `.claude-plugin/`, `hooks/hooks.json`, `commands/`, or `skills/` — the lesson is encoded in README's "Why system functionality and not a plugin?".

## Repository Structure

```
antares-memory/
├── CLAUDE.md                      # This file
├── README.md                      # The product front door — agentic install flow first
├── LICENSE                        # MIT
├── install.sh                     # THE deliverable: idempotent system-mode installer
├── uninstall.sh                   # Exact reverse (never touches memory data)
├── status.sh                      # Diagnostic snapshot (run from the clone)
├── migrate.sh                     # Legacy storage-layout consolidation helper
├── systemd/                       # Daemon unit template
├── scripts/                       # Hook scripts + lobo launchers + prompts + lib/
├── agents-sdk/                    # The 4 headless lobos (cronista/destiller/gardener/index-curator)
├── agents/                        # memory-router + memory-recall subagent definitions
└── docs/                          # The manual: architecture, taxonomy, writing, tuning, troubleshooting
```

## Deploy model

`install.sh` copies into stable system locations and wires everything:

- `scripts/` → `~/.claude/scripts/` (+ `lib/`)
- `agents-sdk/*.mjs` → `~/.claude/agents-sdk/` with `node_modules` symlinked to the stable SDK install at `~/.local/share/antares-memory/sdk/`
- `agents/*.md` → `~/.claude/agents/`
- 5 hook events merged non-destructively into `~/.claude/settings.json`
- systemd unit ExecStart → `~/.claude/scripts/memory-search-daemon.py` (stable — never a repo or cache path)

Re-running `install.sh` IS the update path. `uninstall.sh` removes exactly what install deployed (by this repo's filenames) and never touches `~/.claude/projects/<slug>/memory/`.

## Architecture

5 layers (see `docs/architecture.md` for detail):

1. **Storage** — flat `.md` files at `~/.claude/projects/<slugify(cwd)>/memory/` — Claude Code's native convention; each cwd has its own slug, each with its own auto-loaded `MEMORY.md`
2. **Indexer** — `memory-index.py`: paragraph-aware chunking + sentence-transformers embeddings + SQLite FTS5, per slug
3. **Search** — `memory-search.py` + `memory-search-daemon.py`: hybrid cosine (70%) + BM25 (30%), threshold 0.35, UNIX socket at `$XDG_RUNTIME_DIR/memory-search.sock`
4. **Auto-inject** — `memory-search-hook.sh` on UserPromptSubmit; `memory-journal-init.sh` on SessionStart
5. **Auto-capture** — `memory-chronicle-launch.sh` on PreCompact + SessionEnd (cronista → journal, destilador → memories) + gardener (≥24h) + curator (≥7d), all isolated Agent SDK lobos on the subscription

## Working on this repo

1. Edit here (the clone is the source; on the dev machines the keeper syncs it with GitHub).
2. No version files to bump — versioning is the git history (tag if a milestone warrants it).
3. Commit + push.
4. Deploying to a machine = `./install.sh` on that machine (or, on the dev machines that pre-date the installer, copy the changed files to `~/.claude/scripts|agents-sdk` and restart the daemon if daemon/search files changed).

## Validation discipline

- **Privacy scrub** — the repo is public: no personal names, hostnames, client identifiers, or machine-specific paths outside `$HOME`-relative conventions.
- **Shell hygiene** — `bash -n` every touched script; keep `install.sh`/`uninstall.sh` idempotent and non-clobbering (they must only ever add/remove this repo's own filenames; other files in the target dirs belong to the user).
- **Fresh-machine empathy** — install.sh must fail loudly and early on missing deps, and every failure message must say what to do next.
- This repo is NOT a skill: there is no SKILL.md, no CSO description, no GREEN/trigger evals. The docs/ dir is a manual for humans and agents reading the repo, not auto-loaded context.
