#!/usr/bin/env python3
"""Memory embedding indexer with paragraph-aware chunking.

Reads all .md files in a memory directory (including journal/),
splits into ~120-token chunks with 30-token overlap,
generates embeddings with sentence-transformers, stores in SQLite.
Only re-embeds files with newer mtime than stored value.

Storage model: Claude Code's native slug convention. Memory lives in
`~/.claude/projects/<slugify(cwd)>/memory/`. Each cwd you've ever used
with Claude Code has its own slug dir with its own MEMORY.md (auto-loaded).

Scopes:
    home     — slug dir for $HOME (the "global" by convention)
    current  — slug dir for the current $PWD (or --cwd)
    all      — home + current (default; deduped if same)

Usage:
    memory-index.py                          # index home + current
    memory-index.py --scope home
    memory-index.py --scope current --cwd /path/to/proj
"""

import argparse
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from common import (  # noqa: E402
    ANTARES_MODEL,
    HOME,
    db_path_for,
    home_memory_dir,
    memory_dir_for,
)

import numpy as np  # noqa: E402

# Chunk parameters — tuned for paraphrase-multilingual-MiniLM-L12-v2
# (max_seq_length=128 tokens). Past that window the model simply stops reading,
# silently. Measured on one install before this was fixed: 962 of 10043 chunks
# (9.6%) were over the limit, worst at 1053 tokens, and 51041 tokens of real
# memory text never reached the embedder. FTS5 still indexed that tail, but a
# keyword-only hit peaks at 0.3 * 1.0 = 0.30 against a 0.35 threshold, so it
# could never surface on its own.
#
# The old values WERE the bug: overlap is carried into the next chunk before the
# target budget is spent, so a chunk could reach OVERLAP + TARGET = 150 tokens
# against a 128-token window. The invariant is overlap + target <= window minus
# the 2 special tokens the tokenizer adds.
MODEL_MAX_TOKENS = 128
SPECIAL_TOKENS = 2
HARD_CAP_TOKENS = MODEL_MAX_TOKENS - SPECIAL_TOKENS   # 126: never exceed this
TARGET_TOKENS = 96
OVERLAP_TOKENS = 24                                   # 96 + 24 = 120 <= 126

# Bump this whenever the chunking algorithm or its token budget changes. It is
# what makes a chunker fix reach content that is already indexed — see the
# re-chunk gate in index_scope().
CHUNKER_VERSION = 2


def get_scopes(scope_arg, cwd=None):
    """Return list of (name, memory_dir) tuples for the requested scope(s).

    Deduped: if cwd == $HOME (current and home resolve to the same dir),
    only one entry is returned.
    """
    cwd = cwd or os.getcwd()
    home_dir = home_memory_dir()
    current_dir = memory_dir_for(cwd)

    scopes = []
    if scope_arg in ("home", "all"):
        scopes.append(("home", home_dir))
    if scope_arg in ("current", "all"):
        if current_dir != home_dir:
            scopes.append((f"current:{os.path.basename(os.path.dirname(current_dir))}",
                           current_dir))
    return scopes


def detect_schema_version(conn):
    """Check if DB uses old (file-level) or new (chunk-level) schema."""
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()]
    if "memory_chunks" in tables:
        return 2
    if "memory_embeddings" in tables:
        return 1
    return 0


def init_db(conn):
    """Create v2 schema tables."""
    conn.execute("""CREATE TABLE IF NOT EXISTS memory_chunks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path     TEXT NOT NULL,
        chunk_index   INTEGER NOT NULL,
        content       TEXT NOT NULL,
        embedding     BLOB NOT NULL,
        last_modified REAL NOT NULL,
        file_type     TEXT,
        title         TEXT,
        UNIQUE(file_path, chunk_index)
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS metadata (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )""")
    conn.commit()


def migrate_v1_to_v2(conn):
    """Migrate from file-level to chunk-level schema."""
    print("Migrating schema v1 → v2 (file-level → chunked)...", flush=True)

    conn.execute("""CREATE TABLE memory_chunks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path     TEXT NOT NULL,
        chunk_index   INTEGER NOT NULL,
        content       TEXT NOT NULL,
        embedding     BLOB NOT NULL,
        last_modified REAL NOT NULL,
        file_type     TEXT,
        title         TEXT,
        UNIQUE(file_path, chunk_index)
    )""")

    conn.execute("""
        INSERT INTO memory_chunks (file_path, chunk_index, content, embedding,
                                   last_modified, file_type, title)
        SELECT file_path, 0, content, embedding, 0, file_type, title
        FROM memory_embeddings
    """)

    try:
        conn.execute("DROP TABLE IF EXISTS memory_fts")
    except sqlite3.OperationalError:
        pass
    conn.execute("DROP TABLE memory_embeddings")
    conn.commit()
    print("Migration complete. All files marked for re-chunking.", flush=True)


def get_md_files(memory_dir):
    """Find the .md files that are MEMORIES — not the machinery's own paperwork.

    Excluded, and why:
      * MEMORY.md — the always-on index, loaded natively; indexing it would inject
        the table of contents alongside the things it points at.
      * dot-prefixed files — the lobos' maintenance changelogs live here
        (.gardener-changelog.md, .index-changelog.md). They are an audit trail of
        merges and promotions, not knowledge, and they had 225 chunks in the index
        on one install: a 50 KB running log of housekeeping, competing with real
        memories for the 5 hit slots and injected into prompts as if it were
        something the operator had recorded. Nothing marked them apart, because
        the only filter was the filename MEMORY.md.
    """
    files = []
    for root, _dirs, filenames in os.walk(memory_dir):
        for f in filenames:
            if not f.endswith(".md") or f == "MEMORY.md" or f.startswith("."):
                continue
            files.append(os.path.join(root, f))
    return files


def extract_content(filepath):
    """Read file, strip YAML frontmatter, return content + title."""
    with open(filepath, "r", encoding="utf-8") as f:
        text = f.read()
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].strip()
    title = os.path.basename(filepath)
    for line in text.split("\n"):
        if line.startswith("# "):
            title = line[2:].strip()
            break
    return text, title


def chunk_text(text, tokenizer, target_tokens=TARGET_TOKENS, overlap_tokens=OVERLAP_TOKENS):
    """Split text into overlapping chunks respecting paragraph boundaries."""
    token_ids = tokenizer.encode(text, add_special_tokens=False)
    total_tokens = len(token_ids)

    if total_tokens <= target_tokens:
        return [text]

    paragraphs = re.split(r"\n\n+", text)

    chunks = []
    current_paras = []
    current_count = 0

    for para in paragraphs:
        para_tokens = len(tokenizer.encode(para, add_special_tokens=False))

        if para_tokens > target_tokens:
            if current_paras:
                chunks.append("\n\n".join(current_paras))
                current_paras, current_count = _compute_overlap(
                    current_paras, tokenizer, overlap_tokens
                )

            lines = para.split("\n")
            for line in lines:
                line_tokens = len(tokenizer.encode(line, add_special_tokens=False))
                if current_count + line_tokens > target_tokens and current_paras:
                    chunks.append("\n\n".join(current_paras))
                    current_paras, current_count = _compute_overlap(
                        current_paras, tokenizer, overlap_tokens
                    )
                current_paras.append(line)
                current_count += line_tokens
            continue

        if current_count + para_tokens > target_tokens and current_paras:
            chunks.append("\n\n".join(current_paras))
            current_paras, current_count = _compute_overlap(
                current_paras, tokenizer, overlap_tokens
            )

        current_paras.append(para)
        current_count += para_tokens

    if current_paras:
        chunks.append("\n\n".join(current_paras))

    return _enforce_token_cap(chunks, tokenizer)


def _enforce_token_cap(chunks, tokenizer, hard_cap=HARD_CAP_TOKENS):
    """Guarantee no chunk exceeds the model's input window.

    The paragraph/line logic above is heuristic: it flushes on paragraph and line
    boundaries, and one branch appends a line unconditionally, so a single
    unbroken line longer than the target still produced an oversized chunk (worst
    observed: 1053 tokens). Rather than prove that logic airtight for every input,
    enforce the invariant here. Semantics are already lost at that point; what
    matters is that the text reaches the embedder instead of being cut off by it.
    """
    capped = []
    for chunk in chunks:
        ids = tokenizer.encode(chunk, add_special_tokens=False)
        if len(ids) <= hard_cap:
            capped.append(chunk)
            continue
        # Slice on token windows, but VERIFY each piece by re-encoding the text
        # that will actually be stored. decode(encode(x)) is not length-preserving
        # — whitespace and subword merges shift on the way back — so a window of
        # exactly hard_cap tokens can re-encode to hard_cap + 1 and silently blow
        # the invariant this function exists to guarantee (observed: 127 vs 126).
        start = 0
        while start < len(ids):
            piece_ids = ids[start:start + hard_cap]
            piece = tokenizer.decode(piece_ids).strip()
            while piece and len(tokenizer.encode(piece, add_special_tokens=False)) > hard_cap:
                piece_ids = piece_ids[:-1]
                piece = tokenizer.decode(piece_ids).strip()
            if piece:
                capped.append(piece)
            start += max(1, len(piece_ids))   # max(1,…) so a pathological input cannot loop forever
    return capped


def _compute_overlap(paragraphs, tokenizer, overlap_tokens):
    """Keep trailing paragraphs up to overlap_tokens for the next chunk."""
    overlap_paras = []
    token_count = 0
    for para in reversed(paragraphs):
        para_tokens = len(tokenizer.encode(para, add_special_tokens=False))
        if token_count + para_tokens > overlap_tokens:
            break
        overlap_paras.insert(0, para)
        token_count += para_tokens
    return overlap_paras, token_count


def needs_update(conn, filepath, mtime):
    """Check if file needs re-chunking."""
    row = conn.execute(
        "SELECT last_modified FROM memory_chunks WHERE file_path = ? LIMIT 1",
        (filepath,),
    ).fetchone()
    return row is None or row[0] < mtime


def index_scope(model, scope_name, memory_dir):
    """Index a single scope's memory directory."""
    if not os.path.isdir(memory_dir):
        return

    db_path = db_path_for(memory_dir)
    conn = sqlite3.connect(db_path)
    # WAL: readers do not block on the writer, and a writer that dies does not
    # leave a hot rollback journal that a `mode=ro` reader cannot clear. The
    # default (`delete`) escalates to an EXCLUSIVE lock once the dirty set
    # outgrows the page cache, which on a long run (a chunker bump, a large
    # backlog) locks out the search daemon for the whole pass. Set by the writer
    # because it is persistent in the DB file — readers inherit it.
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass

    version = detect_schema_version(conn)
    if version == 0:
        init_db(conn)
    elif version == 1:
        migrate_v1_to_v2(conn)

    tokenizer = model.tokenizer

    # Does the stored corpus predate the current chunker? This run re-chunks
    # everything if so. Without it, fixing the chunker only ever fixes content
    # written AFTER the fix: indexing is incremental (needs_update skips any file
    # whose mtime hasn't moved), so every chunk already in the DB keeps whatever
    # shape the old code gave it, forever. That is not hypothetical — the token
    # cap added above corrected chunks that were being silently truncated by the
    # embedder, and on an install that simply ran the fixed indexer, 13.6% of
    # chunks stayed over the limit because nothing had touched their files. The
    # fix appeared to work only where the index had been rebuilt from scratch for
    # unrelated reasons. Healing the corpus must not depend on that luck.
    stored_chunker = conn.execute(
        "SELECT value FROM metadata WHERE key = 'chunker_version'"
    ).fetchone()
    rechunk_all = (stored_chunker is None) or (stored_chunker[0] != str(CHUNKER_VERSION))
    if rechunk_all:
        print(f"[{scope_name}] chunker v{CHUNKER_VERSION}: re-chunking every file "
              f"(stored: {stored_chunker[0] if stored_chunker else 'none'})")

    files = get_md_files(memory_dir)
    updated = 0

    for filepath in files:

        # One unreadable file must not cost the whole pass. Without this, a single
        # .md that cannot be decoded or opened — latin-1 bytes, a dangling symlink,
        # a mode-000 file — raised out of the loop and aborted indexing entirely:
        # every healthy file left unindexed, the embedding work discarded, and
        # (because init_db() has already committed) the DB left WITHOUT its FTS
        # table. That is precisely the state that makes every search of the scope
        # fail, so the blackout became permanent: the next run died on the same file.
        # Reproduced in all three variants; the healthy file was absent every time.
        try:
            # getmtime is INSIDE the guard: a dangling symlink raises here, before
            # the file is ever opened, and that was the failure that still aborted
            # the pass after the read itself had been guarded.
            mtime = os.path.getmtime(filepath)
            if not rechunk_all and not needs_update(conn, filepath, mtime):
                continue
            content, title = extract_content(filepath)
        except (OSError, UnicodeDecodeError, ValueError) as e:
            print(f"[{scope_name}] SKIPPING unreadable file: {filepath}: "
                  f"{type(e).__name__}: {e}", flush=True)
            continue
        # Same content gate the INJECTOR already applies. memory-journal-init.sh
        # writes a 36-byte stub (`# Journal: <date>` + `## Sessions`) on every
        # session-start day and then refuses to inject it, because it knows the file
        # is inert — but the indexer only rejected a strictly EMPTY body, so every
        # stub still got a full embedding.
        #
        # Being near-identical to each other, they tie on score and sweep the top-5:
        # measured here, the query "journal sessions" returned 5 of 5 slots filled
        # with empty stubs at 0.825, crowding out every real memory. One more is
        # added per session-day, forever, and nothing prunes them (the gardener's
        # validated delete requires the parent to be the memory dir, which excludes
        # journal/ by design).
        #
        # 50 chars matches the injector's `(( sz > 50 ))`. Verified against this
        # store before applying: it drops exactly the 46 stubs and zero real files —
        # the stubs sit at 34 chars and the smallest real memory is far above 80.
        min_chars = int(os.environ.get("ANTARES_MIN_CONTENT_CHARS", "50"))
        if len(content.strip()) < min_chars:
            # Delete any chunks a previous run already made from it, so the fix
            # reaches what is already indexed instead of only new files.
            conn.execute("DELETE FROM memory_chunks WHERE file_path = ?", (filepath,))
            continue

        file_type = "journal" if "/journal/" in filepath else "memory"
        chunks = chunk_text(content, tokenizer)

        conn.execute("DELETE FROM memory_chunks WHERE file_path = ?", (filepath,))

        for i, chunk_content in enumerate(chunks):
            embedding = model.encode(chunk_content, normalize_embeddings=True)
            embedding_blob = embedding.astype(np.float32).tobytes()
            conn.execute(
                """INSERT INTO memory_chunks
                (file_path, chunk_index, content, embedding, last_modified, file_type, title)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (filepath, i, chunk_content, embedding_blob, mtime, file_type, title),
            )
        updated += 1
        # Commit in batches. The pass used to commit exactly once at the end, so any
        # hard stop — OOM, SIGKILL, power — discarded every embedding computed so
        # far and left the DB in the no-FTS state described above. WAL makes these
        # cheap.
        if updated % 25 == 0:
            conn.commit()

    existing = set(files)
    db_files = set(
        r[0] for r in conn.execute("SELECT DISTINCT file_path FROM memory_chunks")
    )
    for db_file in db_files:
        if db_file not in existing:
            conn.execute("DELETE FROM memory_chunks WHERE file_path = ?", (db_file,))
            updated += 1

    fts_exists = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'"
    ).fetchone()
    if not fts_exists:
        conn.execute(
            "CREATE VIRTUAL TABLE memory_fts USING fts5("
            "title, content, content=memory_chunks, content_rowid=id"
            ")"
        )
        conn.execute(
            "INSERT INTO memory_fts(rowid, title, content) "
            "SELECT id, title, content FROM memory_chunks"
        )
    else:
        conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')")

    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('last_index_time', ?)",
        (str(time.time()),),
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('model_name', ?)", (ANTARES_MODEL,)
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('embedding_dim', '384')"
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('schema_version', '2')"
    )
    # Written LAST, and only on a run that completed: if this run dies partway,
    # the stored version stays behind and the next run re-chunks again rather
    # than declaring a half-converted corpus done.
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('chunker_version', ?)",
        (str(CHUNKER_VERSION),),
    )
    conn.commit()
    conn.close()

    if updated > 0:
        print(f"[{scope_name}] Indexed {updated} file(s).", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Index memory embeddings (chunked)")
    parser.add_argument(
        "-s",
        "--scope",
        default="home",
        choices=["home", "current", "all"],
        help="Scope to index (default: home). 'current' = slug dir for --cwd; "
             "'all' = home + current (deduped if same).",
    )
    parser.add_argument(
        "--cwd",
        default=os.getcwd(),
        help="Working directory used to resolve current scope (default: $PWD).",
    )
    args = parser.parse_args()

    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print(
            "Error: sentence-transformers not installed.\n"
            "Run install.sh to set up the venv.",
            file=sys.stderr,
        )
        sys.exit(1)

    scopes = get_scopes(args.scope, args.cwd)

    if not scopes:
        print(f"No memory directories resolved for scope '{args.scope}' "
              f"(cwd={args.cwd})", file=sys.stderr)
        sys.exit(0)

    # Ensure dirs exist before opening the DBs (creating on first use is OK —
    # they're under ~/.claude/projects/, which Claude Code populates anyway).
    for _name, memory_dir in scopes:
        os.makedirs(memory_dir, exist_ok=True)

    model = SentenceTransformer(ANTARES_MODEL)
    for scope_name, memory_dir in scopes:
        index_scope(model, scope_name, memory_dir)


if __name__ == "__main__":
    main()
