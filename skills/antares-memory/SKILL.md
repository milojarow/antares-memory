---
name: antares-memory
description: Persistent semantic + keyword memory system for Claude Code. Use when writing or editing memory files (`feedback_*`, `reference_*`, `project_*`, `user_*`, `tool_*`); when deciding global vs project scope for a memory; when the user says "save this", "memorize", "remember", "recall", "guarda esto", "olvida esto"; when reading or editing `~/.claude/memory/` (the antares-memory home), `MEMORY.md`, or `journal/*.md`; when tuning embeddings, sentence-transformers, BM25 hybrid search, threshold/weights, or the search daemon; when running `/antares-memory:install|status|migrate|uninstall`; when troubleshooting the daemon (UNIX socket, systemctl), FTS5, the precompact extractor, the `<auto-loaded-memory>` block not appearing, or model issues; when diagnosing why a remembered fact isn't being recalled; when handling the PreCompact headless `claude -p` extraction; when designing the frontmatter taxonomy or dedup discipline.
---

# antares-memory

A turnkey persistent memory system for Claude Code: cross-session knowledge written to flat `.md` files, indexed with embeddings + BM25, auto-injected on `UserPromptSubmit`, and auto-extracted on `PreCompact` before context is lost.

## Overview

Five layers, each documented in `reference/`:

1. **Storage** — `.md` files at `$CLAUDE_MEMORY_HOME` (default `~/.claude/memory/`)
2. **Indexer** — chunked embeddings (paragraph-aware, ~120 tokens, overlap 30) + FTS5, stored in SQLite
3. **Search** — hybrid cosine (70%) + BM25 (30%), threshold 0.35; daemon keeps the model in RAM
4. **Auto-inject** — UserPromptSubmit hook queries the daemon, embeds top-5 hits as an `<auto-loaded-memory>` block
5. **Auto-extract** — PreCompact hook spawns headless `claude -p` to extract memories from the transcript before compaction

## When to use

- The user is writing/editing/recalling memories or anything under `~/.claude/memory/`
- The user mentions "memoria", "memory", "save this", "remember", "recall", "olvida"
- The user is configuring the search (threshold, model, weights) or troubleshooting the daemon
- The user runs an `/antares-memory:*` command and you need to interpret output / next steps
- The user asks why a fact isn't being recalled, or why the `<auto-loaded-memory>` block isn't appearing

**Not for:** writing memories for a generic note-taking app that's not Claude Code's memory system, or for the user's personal journaling outside the `journal/` dir.

## The 5 memory types — at a glance

| Type | Prefix | Use for |
|---|---|---|
| `feedback` | `feedback_*.md` | Corrections from the operator, anti-patterns, validated approaches |
| `reference` | `reference_*.md` | Stable technical knowledge — API quirks, format gotchas, undocumented behavior |
| `project` | `project_*.md` | State of a specific project — clients, services, ongoing work (evolves) |
| `user` | `user_*.md` | Operator's preferences, identity, personal context |
| `tool` | `tool_*.md` | Environment/tool detail — paths, IDs, credential structures, infra topology |

Every memory file MUST have frontmatter — see [reference/frontmatter-taxonomy.md](reference/frontmatter-taxonomy.md).

## Global vs project scope — the decision

- **Global** (`$CLAUDE_MEMORY_HOME`): cross-cutting lessons that apply across all projects
- **Project** (`<project_root>/.claude/memory/`): context that only matters inside one codebase

When in doubt → global. A useful global memory occasionally appearing in a project search is harmless. A project memory that should have been global is invisible everywhere else and gets lost.

Full decision rule + dedup discipline: [reference/writing-memories.md](reference/writing-memories.md).

## The cycle

```
SessionStart ──► reindex if stale ──► load today's journal
                                       ▼
UserPromptSubmit ──► search daemon ──► inject top-5 hits as <auto-loaded-memory>
                                       ▼
Write/Edit a .md ──► PostToolUse async reindex
                                       ▼
PreCompact ──► spawn `claude -p` ──► extracts new memories ──► reindex
```

Every hook is failsafe: if the daemon is down, the venv isn't ready, or any step fails, the hook silently exits with `{}` so the user's flow is never blocked.

## Commands

| Command | Purpose |
|---|---|
| `/antares-memory:install` | First-time setup (venv, model, daemon). Idempotent. |
| `/antares-memory:status` | Diagnose daemon, index, hooks. Start here when something looks off. |
| `/antares-memory:migrate` | Move memories from `~/.claude/projects/<slug>/memory/` into the new home. Dry-run by default. |
| `/antares-memory:uninstall` | Remove daemon + venv. **Preserves your memory files.** |

## Quick reference

**Write a memory** — decide scope (global vs project), choose type, write the file with frontmatter. Filename prefix MUST match type. PostToolUse hook reindexes automatically.

**Force a search** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.sh" "your query"` (or invoke `memory-search.py` directly with the venv python).

**Tune the search** — env vars: `ANTARES_MODEL` (embedding model), `ANTARES_PRECOMPACT_BUDGET` (USD cap for the extractor), `ANTARES_PRECOMPACT_MODEL` (`sonnet` default, drop to `haiku` for cheaper). CLI/daemon flags for one-off queries: `--threshold`, `--vector-weight`, `--keyword-weight`. The hook's default threshold (0.35) is a constant in `memory-search-hook.sh` — edit the script to change it globally. See [reference/tuning-search.md](reference/tuning-search.md).

**Debug** — `/antares-memory:status` first. Then check `$ANTARES_STATE/logs/`. See [reference/troubleshooting.md](reference/troubleshooting.md).

## Common mistakes

- **Writing a memory with `type: feedback` but filename `reference_X.md`** — the indexer trusts the prefix; mismatch means the type filter silently misses the file. Fix: rename the file OR change the frontmatter.
- **Dropping content into `MEMORY.md` instead of a separate file** — `MEMORY.md` is the curated always-loaded index, not a dumping ground. New facts go in their own `.md` file and the indexer picks them up.
- **Editing `~/.claude/projects/<slug>/memory/` after install** — that's the legacy location. The new system uses `$CLAUDE_MEMORY_HOME` (default `~/.claude/memory/`). Run `/antares-memory:migrate` to move legacy files.
- **Putting credentials or client names in a memory and then publishing the project** — memory files are at `~/.claude/memory/`, not in any repo, but project-scoped memories at `<project>/.claude/memory/` ARE tracked unless `.gitignore`d. Add `.claude/memory/` to `.gitignore` for any client repo.
- **Running `pip install sentence-transformers` outside the venv** — install pollutes system Python and doesn't help the daemon. Use `/antares-memory:install` or run `pip install` against `$ANTARES_VENV/bin/pip` directly.

## Reference

- [reference/architecture.md](reference/architecture.md) — the 5 layers, the data flow, what runs where
- [reference/frontmatter-taxonomy.md](reference/frontmatter-taxonomy.md) — the 5 types, fields, examples
- [reference/writing-memories.md](reference/writing-memories.md) — decision rules, dedup discipline, when to enrich vs create
- [reference/tuning-search.md](reference/tuning-search.md) — threshold, weights, top-k, model swap, chunk size
- [reference/troubleshooting.md](reference/troubleshooting.md) — daemon, FTS5, indexer, hooks, extractor
