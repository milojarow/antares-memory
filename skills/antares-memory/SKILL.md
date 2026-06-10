---
name: antares-memory
description: Internal-machinery reference for the antares-memory PIPELINE — the hooks, lobos, and search daemon that give Claude Code persistent memory. Use ONLY when working ON the system itself — running `/antares-memory:install|status|migrate|uninstall`; deploying or migrating it to a new machine; tuning embeddings, sentence-transformers, BM25 hybrid weights/thresholds, or the search daemon; troubleshooting the daemon, FTS5, the capture lobos (cronista/destilador/gardener/index-curator), a missing `<auto-loaded-memory>` block, or diagnosing why a remembered fact isn't being recalled; editing the pipeline's hooks, launchers, or subagents (memory-router/memory-recall); designing the frontmatter taxonomy or dedup discipline. Do NOT use for ROUTINE memory operations — "guarda esto", "save this", "remember/recall X", writing or reading `feedback_*`/`reference_*`/`project_*` memory files, or choosing HOME vs CURRENT slug — the installed hooks and the memory-router/memory-recall subagents handle all of that automatically; this skill adds nothing there. The system runs whether or not the model knows how it works.
---

# antares-memory

> **💭 ACTIVE-SKILL MARKER:** Prefix your reply with 💭 **only on turns where the work touches the `antares-memory` domain** — the antares memory system: embeddings, BM25 hybrid search, auto-extract on PreCompact, journal, daemon, hooks — regardless of the layer/project (frontend, backend, a local script — all count); what matters is whether *this turn* touches the domain. On turns that do NOT touch it (typecheck, build, deploy, git ops, editing or curl in other domains), **omit 💭** even if the skill loaded earlier in the session. If other active skills also apply to the same turn, **stack their emojis** in the prefix.

A turnkey persistent memory system for Claude Code: cross-session knowledge written to flat `.md` files, indexed with embeddings + BM25, auto-injected on `UserPromptSubmit`, and auto-captured on `PreCompact` + `SessionEnd` before context is lost.

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

**Tune the search** — CLI/daemon flags for one-off queries: `--threshold`, `--vector-weight`, `--keyword-weight`. The hook's default threshold (0.35) is hardcoded in `memory-search-hook.sh` — edit the script to change it globally (plugin updates overwrite). **Tune the capture/maintenance lobos** separately via `ANTARES_<LOBO>_MODEL` / `_EFFORT` / `_TIMEOUT` (cronista · destilador · gardener · curator). See [reference/tuning-search.md](reference/tuning-search.md).

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
- [reference/troubleshooting.md](reference/troubleshooting.md) — daemon, FTS5, indexer, hooks, capture lobos
- [reference/lobos-agents-sdk.md](reference/lobos-agents-sdk.md) — the 6 lobos (4 Agent SDK + 2 filesystem subagents): SDK install, isolation, triggers, scaling (digest-in-bash), fork-bomb defenses
