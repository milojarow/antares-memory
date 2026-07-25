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

Two scopes the system operates on:

- **HOME slug** = `slugify($HOME)`. The "global" by convention — loaded when cwd == $HOME.
- **CURRENT slug** = `slugify($PWD)`. The "project" by convention — loaded when cwd matches.

When cwd == $HOME, HOME and CURRENT are the same dir.

Files are POSIX `.md` files. The DB is a derivative — losing it is harmless (`memory-index.py` rebuilds from scratch).

### How `MEMORY.md` gets loaded — no `@`-import required

This is the whole reason the system uses the slug convention: **Claude Code automatically loads `~/.claude/projects/<slug-matching-cwd>/memory/MEMORY.md` into the session at start.**

You do NOT need to add anything to your `~/.claude/CLAUDE.md`. No `@`-import. It just works because that path matches Claude Code's native cwd-slug convention.

The other `.md` files in the dir are NOT loaded this way. They're indexed by `memory-index.py` and pulled in only on semantic match by the `UserPromptSubmit` hook (the `<auto-loaded-memory>` block).

Practical difference:

- `MEMORY.md` → always loaded for the matching cwd (paid every prompt, regardless of relevance)
- All other memory files → loaded only when content semantically matches the current prompt

Keep `MEMORY.md` short — it's overhead per prompt. Use it for directives you want enforced unconditionally for that scope; let semantic recall handle the rest.

### Where "global" lives, and the one variable that decides it

The canonical global store is the `$HOME` slug. An install that predates that
layout can point elsewhere with **`ANTARES_GLOBAL_MEMORY_DIR`**, and both halves
of the system read it: `lib/common.sh` (`antares_home_memory_dir`) and
`lib/common.py` (`home_memory_dir`).

They MUST agree. For a period they did not — the shell honoured the override and
the Python did not — which made `./install.sh` a landmine on the affected
machine: it would have repointed indexing and search at an empty slug dir while
the real store, 550+ memories, sat untouched. No error, no missing file, just
retrieval quietly returning nothing relevant. If you add a third consumer of the
global path, teach it this variable in the same commit.

Set it in the **systemd user environment**, not a shell rc: the search daemon and
every hook are children of systemd, not of an interactive shell.

```
# ~/.config/environment.d/30-antares-memory.conf
ANTARES_GLOBAL_MEMORY_DIR=/home/you/.claude/memory-jarvis
```

The override exists so an install can stay on the canonical SCRIPTS while keeping
a non-canonical STORE. Forking the scripts instead is what produced the worst bug
this system has had: the write side migrated to slugs, the read side did not, and
219 project memories were written to a place nothing could ever read them back
from — for seven weeks, silently.

## 2. Indexer

`scripts/memory-index.py` — runs in three triggers:

| Trigger | When | Behavior |
|---|---|---|
| `SessionStart` (matcher `startup\|resume\|clear\|compact`) | every session | reindex HOME + CURRENT slugs if any `.md` mtime > DB mtime |
| `PostToolUse` (matcher `Write\|Edit\|MultiEdit`) | after every edit | async background reindex of the affected slug |
| Manual | `"$ANTARES_VENV_PY" .../memory-index.py --scope home` | full pass |

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

Both weights and the `0.35` minimum threshold are env-tunable for CLI/daemon queries (not for the hook itself — see [tuning-search.md](tuning-search.md)).

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

`{"op": "ping"}` is the health check used by `./status.sh`.

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

`scripts/memory-elon-musk-launch.sh` — the **elon-musk** lobo — also runs on session start: it commits the memory store to git and pushes it. It is the only component that talks to a remote; everything else writes locally and stops.

- **Why it exists:** nothing ever backed the store up. An audit on one install found 51 memories that had never entered git — one disk, no copy. The index is rebuildable from the `.md` files; the `.md` files are not rebuildable from anything.
- **One repo per machine.** It pushes wherever `~/.claude` already points, so the remote is a property of that clone. Memory stores are per-machine by design; pointing two machines at one repo would make their histories fight.
- **Deterministic bash, no model call** — committing files has no judgment in it, and a headless agent here would spend a model call per session start and add a hallucination surface to a git operation.
- **SessionStart, not SessionEnd:** the capture lobos are fire-and-forget at close and keep writing for a minute or two afterward. Backing up then would snapshot half-written files; by the next start everything has settled.
- **Scope:** stages only the memory paths, never `git add -A` — the same repo holds operator-authored files (persona, settings) that are committed with intent.
- **Diverged remote:** logged and left alone. It never pulls, rebases or forces — a diverged remote means another machine wrote too, and reconciling that is the operator's call.

### PreToolUse — the scope guard

`scripts/memory-scope-guard.sh` runs before every `Write`/`Edit`. If the target
path is a PROJECT-scoped memory file (any `~/.claude/projects/<slug>/memory/`
that is not the global store, or a legacy repo-level `.claude/memory/`), it
injects a reminder as `additionalContext`: **scope is decided per FACT, never
inherited from the file being edited**. Appending a cross-cutting lesson to an
existing project memory silently buries it where no other cwd's session will
ever see it — the guard forces that decision at write time, when the writing
session still holds the fact's full context.

Writes into the global store (`antares_home_memory_dir` — the HOME slug, or
`ANTARES_GLOBAL_MEMORY_DIR` where overridden) pass silently: they already are
the recommended destination.

Deliberately a deterministic bash reflex, not a lobo: it fires on every
Write/Edit, must cost ~nothing, and a headless model call per tool use is the
cascade anti-pattern. The judgment ("is this fact transversal?") stays with the
in-session model; the guard only guarantees the question gets asked. The same
per-fact rule is encoded in the destilador's policy (`memory-distiller-prompt.txt`
§ Scope) so the nightly pipeline can't bury cross-cutting lessons via enrich
either — the lobos run isolated and never see user hooks, so their prompt IS
their guard.

## 5. Auto-capture — the chronicle pipeline

`scripts/memory-chronicle-launch.sh` runs on BOTH `PreCompact` and `SessionEnd`
(fire-and-forget) so a session is captured even when it never compacts. It is a
two-stage pipeline over the NEW transcript segment:

```
transcript ──[cronista]──▶ journal ──[destilador]──▶ memories
```

1. A per-session **watermark** (lines of the `.jsonl` already processed) selects the NEW
   segment (delta). A first-seen in-flight session caps the delta at the last ~300 KB so
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
| Concurrent chronicle runs (a PreCompact + SessionEnd near-collision) | per-session `noclobber` lock file; a run skips if one for that session is already in flight. Scoped to one session id, so a leftover file can only ever block re-chronicling that one session. |
| Concurrent gardener / curator / elon-musk runs (several sessions closing at once) | `flock -n` on fd 9, taken inside the background subshell. **Not** a pid-in-a-file lock: that is only released by a `trap … EXIT`, so a lobo killed hard (SIGKILL, OOM, power loss) leaves the file behind and every later session skips forever — silently, since a wedged lobo logs exactly like a busy one. This bit a real install: a curator sat out 259 consecutive closes over ~7 weeks. The kernel releases an `flock` however the process dies. |

## Failure modes (designed)

- Daemon down → hook emits `{}`, prompt continues with no auto-loaded memory.
- Venv missing → reindex hooks emit `{}` and skip.
- A capture lobo times out / errors → log says `CRONISTA rc=…` or `DESTILADOR rc=…` (nonzero); partial writes are kept, and the watermark only advances on cronista success, so the delta is retried next run.
- SQLite locked (very rare) → search returns empty hits, log line, no user-visible failure.
- Transcript file missing → log says `SKIP no transcript`, exit 0.
- elon-musk can't push (offline, unreachable remote) → the commits still land locally and the next session start pushes the backlog. A *diverged* remote logs `DIVERGED` and stops.

## Failure modes that are NOT designed — the silent ones

Every mode above announces itself. These do not, and both were found in the field on real installs:

- **A launcher cancelled by its hook budget.** Hooks are killed if they overrun their `timeout`, and the harness may default that budget to something far shorter than other events (Claude Code gives SessionEnd hooks ~1.5 s unless the hook declares its own). Whatever a launcher does in the *foreground* — building a digest, slicing a transcript, reindexing — is spent from that budget, so it can be killed before dispatching its lobo. **Always declare a `timeout` on every hook entry, and keep foreground work far under it.** A digest built with two processes per memory measured 2–10 s at ~530 memories and grew with the store; `antares_build_digest` (one awk pass) does the same work in ~20 ms.
- **A component that dies and takes the whole system with it, quietly.** A reindexer that never completes leaves search answering from a stale index — the lobos all look healthy, recall just silently gets worse. If a component has no log line, it cannot be diagnosed; give every scheduled component a log, and check freshness (index time, last commit) rather than liveness.
