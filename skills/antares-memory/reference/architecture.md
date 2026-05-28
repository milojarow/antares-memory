# Architecture

Five layers. Each runs independently; failures degrade gracefully (the user's prompt never blocks).

## 1. Storage

```
$CLAUDE_MEMORY_HOME/            ← default ~/.claude/memory/
├── MEMORY.md                   ← always-loaded index (curated by operator)
├── feedback_*.md               ← corrections, anti-patterns
├── reference_*.md              ← stable technical knowledge
├── project_*.md                ← project state
├── user_*.md                   ← operator preferences
├── tool_*.md                   ← env/tool detail
├── journal/
│   └── YYYY-MM-DD.md           ← one file per day
└── .memory-index.db            ← SQLite (embeddings + FTS5)

<project_root>/.claude/memory/   ← project-scoped, same schema, opt-in
├── *.md
└── .memory-index.db
```

Files are POSIX `.md` files. The DB is a derivative — losing it is harmless (`memory-index.py` rebuilds from scratch).

### How `MEMORY.md` gets loaded

`MEMORY.md` is the always-on layer. It's NOT injected by any hook — instead, it relies on Claude Code's CLAUDE.md `@`-import mechanism. The operator adds one line to their `~/.claude/CLAUDE.md`:

```
@~/.claude/memory/MEMORY.md
```

Claude Code loads `~/.claude/CLAUDE.md` automatically into every session's system prompt, and `@`-imports cascade — so `MEMORY.md` content lands in the system prompt before any hook fires.

The other `.md` files in the directory are NOT loaded this way. They're indexed and pulled in only on semantic match by the `UserPromptSubmit` hook (the `<auto-loaded-memory>` block). Difference matters:

- `MEMORY.md` → always loaded (paid for every prompt, regardless of relevance)
- All other memory files → loaded only when their content semantically matches the current prompt

Keep `MEMORY.md` short — it's overhead per prompt. Use it for directives you want enforced unconditionally; let semantic recall handle the rest.

## 2. Indexer

`scripts/memory-index.py` — runs in three triggers:

| Trigger | When | Behavior |
|---|---|---|
| `SessionStart` (matcher `startup\|resume\|clear\|compact`) | every session | reindex if any `.md` mtime > DB mtime |
| `PostToolUse` (matcher `Write\|Edit\|MultiEdit`) | after every edit | async background reindex of the affected scope |
| Manual | `bash $ANTARES_VENV_PY .../memory-index.py` | full pass |

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

## 3. Search

`scripts/memory-search.py` / `scripts/memory-search-daemon.py` — hybrid search.

### Hybrid formula

```
final_score = 0.7 × cosine(query_embedding, chunk_embedding)
            + 0.3 × normalized_bm25(query_text, chunk)
```

Both weights and the `0.35` minimum threshold are env-tunable.

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
 "timing_ms": 87, "scopes_searched": ["global", "project:foo"]}
```

`{"op": "ping"}` is the health check used by `/antares-memory:status`.

## 4. Auto-inject

### UserPromptSubmit

`scripts/memory-search-hook.sh` runs on every prompt ≥ 30 chars:

1. Read prompt + cwd from hook stdin.
2. Query the daemon (`top_k=5`, `threshold=0.35`).
3. For each hit, read the full file content.
4. Emit `<auto-loaded-memory>...</auto-loaded-memory>` as `additionalContext`.

If the daemon is down or returns no hits, emits `{}` — no context injected, user's prompt proceeds unchanged.

### SessionStart

`scripts/memory-journal-init.sh` runs on session start:

1. Create today's `journal/YYYY-MM-DD.md` if missing (with a `# Journal: YYYY-MM-DD` header).
2. Read today's file (up to 15 KB) and yesterday's (up to 8 KB).
3. Emit both as `<journal-today>` and `<journal-yesterday>` `additionalContext`.

This means yesterday's lessons are in context at the start of every session.

## 5. Auto-extract

`scripts/memory-precompact-extract.sh` is the most expensive layer — runs when Claude Code is about to compact the conversation.

1. Extract text-only transcript from the JSONL (capped at last 100 KB) to a temp file.
2. Detect whether the parent session was inside a project (walk up looking for `.claude/memory/`).
3. Build a contextualized prompt for the sub-Claude (telling it where global lives, whether a project memory dir exists).
4. Spawn `claude -p` headless:
   - `--model sonnet` (cheap enough for extraction tasks)
   - `--max-budget-usd 1.00` (hard cap)
   - `--no-session-persistence` (transient)
   - `--permission-mode bypassPermissions` (sub-claude can write freely under the memory dirs)
   - `--append-system-prompt-file memory-precompact-prompt.txt` (the taxonomy + decision rules)
5. Sub-Claude writes new memories via `Write`/`Edit`.
6. Parent script reindexes synchronously so the new memories are searchable in the next session.

A single-flight lock at `$XDG_RUNTIME_DIR/antares-memory-precompact.lock` prevents concurrent extractors.

The `CLAUDE_HEADLESS=1` env var is exported before the `claude -p` call. All hooks check this and short-circuit (`echo '{}'; exit 0`) when set — prevents recursive memory search inside the extractor sub-process.

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
