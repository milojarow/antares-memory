---
name: antares-memory
description: Persistent semantic + keyword memory system for Claude Code. Use when writing or editing memory files (`feedback_*`, `reference_*`, `project_*`, `user_*`, `tool_*`); when deciding HOME vs CURRENT slug for a memory; when the user says "save this", "memorize", "remember", "recall", "guarda esto", "olvida esto"; when reading or editing memory files under `~/.claude/projects/<slug>/memory/`, `MEMORY.md`, or `journal/*.md`; when tuning embeddings, sentence-transformers, BM25 hybrid search, threshold/weights, or the search daemon; when running `/antares-memory:install|status|migrate|uninstall`; when troubleshooting the daemon, FTS5, the precompact extractor, the `<auto-loaded-memory>` block not appearing, or model issues; when diagnosing why a remembered fact isn't being recalled; when handling the PreCompact extraction (isolated Agent SDK subagents — "lobos"); when designing the frontmatter taxonomy or dedup discipline.
---

# antares-memory

> **💭 ACTIVE-SKILL MARKER:** Prefija tu reply con 💭 **solo en turnos donde el trabajo toca el dominio de `antares-memory`** — sistema antares de memoria — embeddings, BM25 hybrid search, auto-extract on PreCompact, journal, daemon, hooks. La **capa/proyecto da igual** (frontend, backend, n8n, script local — todos valen): lo que importa es si *este turno* toca el dominio. En turnos que NO lo tocan (typecheck, build, deploy, git ops, edición o curl de otros dominios), **omite 💭** aunque la skill se haya cargado antes en la sesión. Si otras skills activas también aplican al mismo turno, **apila sus emojis** en el prefijo.

A turnkey persistent memory system for Claude Code: cross-session knowledge written to flat `.md` files, indexed with embeddings + BM25, auto-injected on `UserPromptSubmit`, and auto-extracted on `PreCompact` before context is lost.

## Storage model — native Claude Code slug convention

Memories live at:

```
~/.claude/projects/<slugify(cwd)>/memory/
```

Each cwd you've ever worked in with Claude Code has its own slug dir. Claude Code already auto-loads `MEMORY.md` from the matching slug at session start — **no `@`-import in your `~/.claude/CLAUDE.md` is needed.**

Two scopes the skill cares about:

- **HOME slug** — slugify($HOME). The "global" by convention. Loaded automatically when cwd == $HOME. Holds cross-cutting lessons.
- **CURRENT slug** — slugify($PWD). Loaded automatically when cwd matches. Holds cwd-specific context.

When cwd == $HOME, HOME and CURRENT collapse into one dir — there is only one to write to.

## Overview

Five layers, each documented in `reference/`:

1. **Storage** — `.md` files in slug dirs (above)
2. **Indexer** — chunked embeddings (paragraph-aware, ~120 tokens, overlap 30) + FTS5, stored in `<slug>/memory/.memory-index.db`
3. **Search** — hybrid cosine (70%) + BM25 (30%), threshold 0.35; daemon keeps the model in RAM
4. **Auto-inject** — UserPromptSubmit hook queries the daemon, embeds top-5 hits as an `<auto-loaded-memory>` block
5. **Auto-capture** — `PreCompact` + `SessionEnd` run the **chronicle pipeline** (`cronista` → `destilador`, isolated SDK): the cronista appends the session's episodic journal, the destilador distills durable memories from the same delta. Routing, recall, and base/index maintenance are separate lobos — see [reference/lobos-agents-sdk.md](reference/lobos-agents-sdk.md)

## When to use

- The user is writing/editing/recalling memories or anything under `~/.claude/projects/<slug>/memory/`
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

## HOME vs CURRENT — the decision

- **HOME**: cross-cutting lessons that apply across all cwds. Tool quirks, behavioral feedback, environmental facts.
- **CURRENT**: context that only matters when working in this cwd. Project architecture, ongoing TODOs, client info.

When in doubt → HOME. A useful HOME memory occasionally appearing in another cwd is harmless. A CURRENT memory that should have been HOME is invisible everywhere else and gets lost.

Full decision rule + dedup discipline: [reference/writing-memories.md](reference/writing-memories.md).

## The cycle

```
SessionStart ──► reindex if stale ──► load today's journal (from HOME slug)
                                       ▼
UserPromptSubmit ──► search daemon ──► inject top-5 hits as <auto-loaded-memory>
                                       ▼
Write/Edit a .md ──► PostToolUse async reindex (of the affected slug)
                                       ▼
PreCompact ──► chronicle: cronista (journal) → destilador (memories) ──► reindex
                                       ▼
SessionEnd ──► chronicle (same) + gardener (≥24h) + index-curator (≥7d) — fire-and-forget
```

Plus the always-on layer: Claude Code itself loads `MEMORY.md` of the cwd's slug at session start.

Every hook is failsafe: if the daemon is down, the venv isn't ready, or any step fails, the hook silently exits with `{}` so the user's flow is never blocked.

## Commands

| Command | Purpose |
|---|---|
| `/antares-memory:install` | First-time setup (venv, model, daemon, HOME slug dir). Idempotent. |
| `/antares-memory:status` | Diagnose daemon, indices for HOME + CURRENT slugs, hooks. Start here. |
| `/antares-memory:migrate` | Consolidate stragglers from a non-standard path (e.g. legacy v0.1.x `~/.claude/memory/`) into the HOME slug. |
| `/antares-memory:uninstall` | Remove daemon + venv. **Preserves all memory files** (every slug dir). |

## Quick reference

**Write a memory** — decide scope (HOME vs CURRENT), choose type, write the file with frontmatter under the slug's `memory/` dir. Filename prefix MUST match type. PostToolUse hook reindexes automatically.

**Force a search** — invoke `memory-search.py` directly with the venv python (full output, all flags).

**Tune the search** — env vars: `ANTARES_MODEL`, `ANTARES_PRECOMPACT_BUDGET`, `ANTARES_PRECOMPACT_MODEL`, `ANTARES_PRECOMPACT_TIMEOUT`. CLI/daemon flags for one-off queries: `--threshold`, `--vector-weight`, `--keyword-weight`. The hook's default threshold (0.35) is hardcoded in `memory-search-hook.sh` — edit the script to change it globally (plugin updates overwrite). See [reference/tuning-search.md](reference/tuning-search.md).

**Debug** — `/antares-memory:status` first. Then check `$ANTARES_STATE/logs/` (default `~/.local/state/antares-memory/logs/`). See [reference/troubleshooting.md](reference/troubleshooting.md).

## Common mistakes

- **Writing a memory with `type: feedback` but filename `reference_X.md`** — the indexer trusts the prefix; mismatch means the type filter silently misses the file. Fix: rename the file OR change the frontmatter.
- **Dropping content into `MEMORY.md` instead of a separate file** — `MEMORY.md` is the curated always-loaded index for its slug, not a dumping ground. New facts go in their own `.md` file and the indexer picks them up.
- **Writing a memory while in the "wrong" cwd** — the memory will go to that cwd's slug, not HOME. If you wanted it global, write while cwd == $HOME, or move it after (`mv` + reindex).
- **Adding `@~/.claude/memory/MEMORY.md` to `~/.claude/CLAUDE.md`** — that's the v0.1.x pattern. In v0.2+, MEMORY.md auto-loads via Claude Code's path convention. The `@`-import would add nothing (no such file at that path) or duplicate context.
- **Running `pip install sentence-transformers` outside the venv** — install pollutes system Python and doesn't help the daemon. Use `/antares-memory:install` or run `pip install` against `$ANTARES_VENV/bin/pip` directly.

## Reference

- [reference/architecture.md](reference/architecture.md) — the 5 layers, the data flow, slug-based storage in detail
- [reference/frontmatter-taxonomy.md](reference/frontmatter-taxonomy.md) — the 5 types, fields, examples
- [reference/writing-memories.md](reference/writing-memories.md) — decision rules, dedup discipline, when to enrich vs create
- [reference/tuning-search.md](reference/tuning-search.md) — threshold, weights, top-k, model swap, chunk size
- [reference/troubleshooting.md](reference/troubleshooting.md) — daemon, FTS5, indexer, hooks, extractor
- [reference/lobos-agents-sdk.md](reference/lobos-agents-sdk.md) — the 5 lobos (Agent SDK subagents): SDK install, isolation, triggers, scaling (digest-in-bash), fork-bomb defenses
