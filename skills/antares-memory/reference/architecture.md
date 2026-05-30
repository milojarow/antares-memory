# Architecture

Five layers. Each runs independently; failures degrade gracefully (the user's prompt never blocks).

## 1. Storage — slug-based, native to Claude Code

Memories live at:

```
~/.claude/projects/<slugify(cwd)>/memory/
```

`slugify` is approximately `cwd.replace('/', '-')`. Some examples:

| cwd | slug | memory dir |
|---|---|---|
| `/home/juan` | `-home-juan` | `~/.claude/projects/-home-juan/memory/` |
| `/home/juan/projects/foo` | `-home-juan-projects-foo` | `~/.claude/projects/-home-juan-projects-foo/memory/` |

Each slug dir contains:

```
~/.claude/projects/<slug>/memory/
├── MEMORY.md                ← auto-loaded by Claude Code when cwd matches this slug
├── feedback_*.md            ← corrections, anti-patterns
├── reference_*.md           ← stable technical knowledge
├── project_*.md             ← project state
├── user_*.md                ← operator preferences
├── tool_*.md                ← env/tool detail
├── journal/                 ← only in the HOME slug — one journal store regardless of cwd
│   └── YYYY-MM-DD.md
└── .memory-index.db         ← SQLite (embeddings + FTS5)
```

Two scopes the skill operates on:

- **HOME slug** = `slugify($HOME)`. The "global" by convention — loaded when cwd == $HOME.
- **CURRENT slug** = `slugify($PWD)`. The "project" by convention — loaded when cwd matches.

When cwd == $HOME, HOME and CURRENT are the same dir.

Files are POSIX `.md` files. The DB is a derivative — losing it is harmless (`memory-index.py` rebuilds from scratch).

### How `MEMORY.md` gets loaded — no `@`-import required

This is the whole reason the skill uses the slug convention: **Claude Code automatically loads `~/.claude/projects/<slug-matching-cwd>/memory/MEMORY.md` into the session at start.**

You do NOT need to add anything to your `~/.claude/CLAUDE.md`. No `@`-import. It just works because that path matches Claude Code's native cwd-slug convention.

The other `.md` files in the dir are NOT loaded this way. They're indexed by `memory-index.py` and pulled in only on semantic match by the `UserPromptSubmit` hook (the `<auto-loaded-memory>` block).

Practical difference:

- `MEMORY.md` → always loaded for the matching cwd (paid every prompt, regardless of relevance)
- All other memory files → loaded only when content semantically matches the current prompt

Keep `MEMORY.md` short — it's overhead per prompt. Use it for directives you want enforced unconditionally for that scope; let semantic recall handle the rest.

## 2. Indexer

`scripts/memory-index.py` — runs in three triggers:

| Trigger | When | Behavior |
|---|---|---|
| `SessionStart` (matcher `startup\|resume\|clear\|compact`) | every session | reindex HOME + CURRENT slugs if any `.md` mtime > DB mtime |
| `PostToolUse` (matcher `Write\|Edit\|MultiEdit`) | after every edit | async background reindex of the affected slug |
| Manual | `bash $ANTARES_VENV_PY .../memory-index.py --scope home` | full pass |

### Chunking

Paragraph-aware split into ~120-token chunks with 30-token overlap. The default model (`paraphrase-multilingual-MiniLM-L12-v2`) has a 128-token max sequence length — chunks stay under to avoid silent truncation.

### Storage schema (v2)

```sql
CREATE TABLE memory_chunks (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path     TEXT NOT NULL,
    chunk_index   INTEGER NOT NULL,
    content       TEXT NOT NULL,
    embedding     BLOB NOT NULL,
    last_modified REAL NOT NULL,
    file_type     TEXT,           -- 'memory' or 'journal'
    title         TEXT,
    UNIQUE(file_path, chunk_index)
);

CREATE VIRTUAL TABLE memory_fts USING fts5(
    title, content,
    content=memory_chunks,
    content_rowid=id
);
```

The indexer migrates v1 (file-level) → v2 (chunked) automatically on first run after upgrade.

Each slug has its own `.memory-index.db`. The daemon opens whichever DBs it needs per query (HOME, CURRENT, or both).

## 3. Search

`scripts/memory-search.py` / `scripts/memory-search-daemon.py` — hybrid search.

### Hybrid formula

```
final_score = 0.7 × cosine(query_embedding, chunk_embedding)
            + 0.3 × normalized_bm25(query_text, chunk)
```

Both weights and the `0.35` minimum threshold are env-tunable for CLI/daemon queries (not for the hook itself — see SKILL.md).

### Per-file deduplication

Chunks belong to files. After scoring all chunks, keep only the best-scoring chunk per file. Output is one row per file, with `chunk_index` indicating which chunk matched.

### Daemon

`memory-search-daemon.py` listens on a UNIX socket at `$XDG_RUNTIME_DIR/memory-search.sock`. The model loads once (~3 seconds) into RAM; subsequent queries are sub-100ms.

Each request opens a **read-only** SQLite connection (`?mode=ro`), so the daemon never locks against `memory-index.py` running concurrently.

Wire protocol (one JSON request, one JSON response, newline-terminated):

```json
{"op": "search", "query": "...", "cwd": "/path", "scope": "all",
 "top_k": 5, "threshold": 0.35, "types": "all"}

{"ok": true, "hits": [{"score": 0.71, "path": "...", "snippet": "..."}],
 "timing_ms": 87, "scopes_searched": ["home", "current:..."]}
```

`{"op": "ping"}` is the health check used by `/antares-memory:status`.

## 4. Auto-inject

### UserPromptSubmit

`scripts/memory-search-hook.sh` runs on every prompt ≥ 30 chars:

1. Read prompt + cwd from hook stdin.
2. Query the daemon with `cwd` so it resolves the HOME + CURRENT slugs.
3. For each hit, read the full file content.
4. Emit `<auto-loaded-memory>...</auto-loaded-memory>` as `additionalContext`.

If the daemon is down or returns no hits, emits `{}` — no context injected, user's prompt proceeds unchanged.

### SessionStart

`scripts/memory-journal-init.sh` runs on session start:

1. Create today's `<HOME-slug>/memory/journal/YYYY-MM-DD.md` if missing.
2. Read today's file (up to 15 KB) and yesterday's (up to 8 KB) — both from the HOME slug.
3. Emit both as `<journal-today>` and `<journal-yesterday>` `additionalContext`.

The journal lives in the HOME slug only — one journal store regardless of cwd. (`MEMORY.md` is per slug; the journal is global.)

## 5. Auto-capture — the chronicle pipeline

`scripts/memory-chronicle-launch.sh` runs on BOTH `PreCompact` and `SessionEnd`
(fire-and-forget) so a session is captured even when it never compacts. It is a
two-stage pipeline over the NEW transcript segment:

```
transcript ──[cronista]──▶ journal ──[destilador]──▶ memories
```

1. A per-session **watermark** (lines of the `.jsonl` already processed) selects the NEW
   segment (delta). A first-seen in-flight session caps the delta at the last ~100 KB so
   the lobo doesn't choke on a multi-MB backlog.
2. Preprocess the delta to user/assistant text (jq, tool calls stripped).
3. **cronista** (`agents-sdk/cronista.mjs`, isolated SDK) appends the episodic chronicle
   of the delta to `journal/session-<id>.md`; then the watermark advances.
4. **destilador** (`agents-sdk/destiller.mjs`, isolated SDK), chained on the SAME delta,
   distills durable memories — dedup against an inline memories digest (no base sweep).
5. Reindex synchronously so the new journal + memories are searchable next session.

One watermark → no double-capture between journal and memories. A per-session lock
prevents concurrent runs. `CLAUDE_HEADLESS=1` is exported before each lobo (all hooks
short-circuit when set — the fork-bomb guard). Both run with `settingSources: []` (no
persona bias) and a capped `maxTurns`. Knobs: `ANTARES_CRONISTA_*` / `ANTARES_DISTILLER_*`
(model / effort / timeout).

## Cross-process coordination

| Concern | Solution |
|---|---|
| Multiple Claude sessions running simultaneously | They all share one daemon process via the socket |
| Two PostToolUse reindexes racing | The indexer is idempotent — only re-embeds files with mtime > stored. Last write wins on the chunks table (DELETE + INSERT per file). |
| Daemon lock during reindex | Daemon opens DB read-only — no lock contention. |
| Re-entry from headless sub-claude | `CLAUDE_HEADLESS=1` is set; every hook checks it and exits silently. |
| Concurrent PreCompact extractors | `flock`-style noclobber lock file in `$XDG_RUNTIME_DIR`. |

## Failure modes (designed)

- Daemon down → hook emits `{}`, prompt continues with no auto-loaded memory.
- Venv missing → reindex hooks emit `{}` and skip.
- Sub-claude budget exceeded → log says `BUDGET_EXCEEDED`, partial writes (if any) are kept, reindex still runs.
- SQLite locked (very rare) → search returns empty hits, log line, no user-visible failure.
- Transcript file missing → log says `SKIP no transcript_path`, exit 0.
