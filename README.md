# antares-memory-skill

**Persistent semantic + keyword memory for Claude Code — turnkey.**

## What is this?

A complete memory system for Claude Code that survives across sessions: the assistant writes lessons, gotchas, and decisions to disk as `.md` files; a hybrid search daemon (embeddings + BM25) makes them recallable; relevant memories auto-inject on every prompt; and on context compaction, a headless `claude -p` extracts new memories from the transcript before history is lost.

Everything ships in one plugin. After `/antares-memory:install`, you get:

- **Storage** at `~/.claude/projects/<slugify(cwd)>/memory/` — Claude Code's native location. Each cwd has its own slug dir. Memory files use a frontmatter taxonomy (`feedback_*`, `reference_*`, `project_*`, `user_*`, `tool_*`)
- **Indexer** (`sentence-transformers` multilingual model) chunking files and storing embeddings per-slug in SQLite
- **Search daemon** — UNIX socket, model pre-warmed in RAM, hybrid cosine + BM25, queries HOME + CURRENT slugs
- **4 hooks** wired automatically (UserPromptSubmit, SessionStart, PreCompact, PostToolUse)
- **Journal** (`<HOME-slug>/memory/journal/YYYY-MM-DD.md`) loaded at session start
- **Zero `@`-imports** in your `~/.claude/CLAUDE.md` — Claude Code already auto-loads `MEMORY.md` from the cwd's slug

### Why this skill exists

- **Cross-session knowledge has to be re-derived every conversation otherwise.** A flat `CLAUDE.md` doesn't scale past a few dozen rules.
- **Semantic recall beats keyword grep.** Hybrid search (70% cosine + 30% BM25) finds memories you didn't know to look for.
- **Sessions are captured before the transcript is lost.** A headless pipeline (cronista → destilador) runs on PreCompact *and* SessionEnd — on compaction it grabs the segment still in memory; on close it captures whatever the session never compacted.
- **Daemon keeps the model warm.** First search after install is slow (model load); subsequent searches are sub-100ms.
- **Slug-based storage mirrors Claude Code's native convention.** `MEMORY.md` auto-loads without any `@`-import — fully transparent for the operator.

## The skill

| Skill | Description |
|-------|-------------|
| **antares-memory** | When to write a memory, where (HOME vs CURRENT slug), frontmatter taxonomy, tuning the search, troubleshooting the daemon, and operating the `/antares-memory:*` commands |

## Installation

Add the marketplace in Claude Code:

```
/plugin marketplace add milojarow/antares-memory-skill
```

Install the plugin:

```
/plugin install antares-memory-skill@antares-memory-skill
```

Run the one-time setup (creates venv, downloads the embedding model ~400MB, enables systemd daemon, seeds your HOME slug's MEMORY.md):

```
/antares-memory:install
```

That's it. Open a new session from `$HOME` and `MEMORY.md` is already in context — Claude Code's native cwd-slug convention loads it automatically.

## Commands

| Command | Purpose |
|---|---|
| `/antares-memory:install` | One-time setup: venv, model, daemon, HOME slug dir. Idempotent. |
| `/antares-memory:status` | Diagnose daemon, indices, hook health for HOME + CURRENT slugs. |
| `/antares-memory:migrate` | Consolidate stragglers from a non-standard path (legacy v0.1.x `~/.claude/memory/`) into the HOME slug. |
| `/antares-memory:uninstall` | Remove daemon, venv, dirs. Preserves all memory files. |

## Requirements

- Linux with systemd user instance (or macOS with launchd — daemon falls back to manual `python3 daemon.py &`)
- `python3 >= 3.10`, `jq`, `socat`, `sqlite3` (with FTS5)
- ~400 MB disk for the multilingual embedding model
- ~1.5 GB RAM for the daemon (model + index)

## License

MIT
